module MOM_variables

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_domains, only : MOM_domain_type, get_domain_extent, group_pass_type
use MOM_debugging, only : hchksum
use MOM_error_handler, only : MOM_error, FATAL
use MOM_grid, only : ocean_grid_type
use MOM_EOS, only : EOS_type

use coupler_types_mod, only : coupler_1d_bc_type, coupler_2d_bc_type
use coupler_types_mod, only : coupler_type_spawn, coupler_type_destructor

implicit none ; private

#include <MOM_memory.h>

public allocate_surface_state, deallocate_surface_state, MOM_thermovar_chksum
public ocean_grid_type, alloc_BT_cont_type, dealloc_BT_cont_type

type, public :: p3d
  real, dimension(:,:,:), pointer :: p => NULL()
end type p3d
type, public :: p2d
  real, dimension(:,:), pointer :: p => NULL()
end type p2d

!>   The following structure contains pointers to various fields
!! which may be used describe the surface state of MOM, and which
!! will be returned to a the calling program
type, public :: surface
  real, allocatable, dimension(:,:) :: &
    SST, &      !< The sea surface temperature in C.
    SSS, &      !< The sea surface salinity in psu.
    sfc_density, & !< The mixed layer density in kg m-3.
    Hml, &      !< The mixed layer depth in m.
    u, &        !< The mixed layer zonal velocity in m s-1.
    v, &        !< The mixed layer meridional velocity in m s-1.
    sea_lev, &  !< The sea level in m.  If a reduced surface gravity is
                !! used, that is compensated for in sea_lev.
    ocean_mass, &  !< The total mass of the ocean in kg m-2.
    ocean_heat, &  !< The total heat content of the ocean in C kg m-2.
    ocean_salt, &  !< The total salt content of the ocean in kgSalt m-2.
    salt_deficit   !< The salt needed to maintain the ocean column at a minimum
                   !! salinity of 0.01 PSU over the call to step_MOM, in kgSalt m-2.
  logical :: T_is_conT = .false. !< If true, the temperature variable SST is
                         !! actually the conservative temperature, in degC.
  logical :: S_is_absS = .false. !< If true, the salinity variable SSS is
                         !! actually the absolute salinity, in g/kg.
  real, pointer, dimension(:,:) :: &
    taux_shelf => NULL(), &  !< The zonal and meridional stresses on the ocean
    tauy_shelf => NULL(), &  !< under shelves, in Pa.
    frazil => NULL(), &  !< The energy needed to heat the ocean column to the
                         !! freezing point over the call to step_MOM, in J m-2.
    TempxPmE => NULL(), &  !< The net inflow of water into the ocean times
                         !! the temperature at which this inflow occurs during
                         !! the call to step_MOM, in deg C kg m-2.
                         !!   This should be prescribed in the forcing fields,
                         !! but as it often is not, this is a useful heat budget
                         !! diagnostic.
    internal_heat => NULL() !< Any internal or geothermal heat sources that
                         !! are applied to the ocean integrated over the call
                         !! to step_MOM, in deg C kg m-2.
  type(coupler_2d_bc_type) :: &
    tr_fields            !< A structure that may contain an  array of named
                         !! fields describing tracer-related quantities.
       !!! NOTE: ALL OF THE ARRAYS IN TR_FIELDS USE THE COUPLER'S INDEXING
       !!!       CONVENTION AND HAVE NO HALOS!  THIS IS DONE TO CONFORM TO
       !!!       THE TREATMENT IN MOM4, BUT I DON'T LIKE IT!
  logical :: arrays_allocated = .false.  !< A flag that indicates whether
                         !! the surface type has had its memory allocated.
end type surface

!>   The thermo_var_ptrs structure contains pointers to an assortment of
!! thermodynamic fields that may be available, including potential temperature,
!! salinity, heat capacity, and the equation of state control structure.
type, public :: thermo_var_ptrs
!   If allocated, the following variables have nz layers.
  real, pointer :: T(:,:,:) => NULL()   !< Potential temperature in C.
  real, pointer :: S(:,:,:) => NULL()   !< Salnity in psu or ppt.
  type(EOS_type), pointer :: eqn_of_state => NULL() !< Type that indicates the
                                        !! equation of state to use.
  real :: P_Ref          !<   The coordinate-density reference pressure in Pa.
                         !! This is the pressure used to calculate Rml from
                         !! T and S when eqn_of_state is associated.
  real :: C_p            !<   The heat capacity of seawater, in J K-1 kg-1.
                         !! When conservative temperature is used, this is
                         !! constant and exactly 3991.86795711963 J K kg-1.
  logical :: T_is_conT = .false. !< If true, the temperature variable tv%T is
                         !! actually the conservative temperature, in degC.
  logical :: S_is_absS = .false. !< If true, the salinity variable tv%S is
                         !! actually the absolute salinity, in g/kg.
  real, pointer, dimension(:,:) :: &
!  These arrays are accumulated fluxes for communication with other components.
    frazil => NULL(), &  !<   The energy needed to heat the ocean column to the
                         !! freezing point since calculate_surface_state was
                         !! last called, in units of J m-2.
    salt_deficit => NULL(), & !<   The salt needed to maintain the ocean column
                         !! at a minumum salinity of 0.01 PSU since the last time
                         !! that calculate_surface_state was called, in units
                         !! of gSalt m-2.
    TempxPmE => NULL(), & !<   The net inflow of water into the ocean times the
                         !! temperature at which this inflow occurs since the
                         !! last call to calculate_surface_state, in units of
                         !! deg C kg m-2. This should be prescribed in the
                         !! forcing fields, but as it often is not, this is a
                         !! useful heat budget diagnostic.
    internal_heat => NULL() !< Any internal or geothermal heat sources that
                         !! have been applied to the ocean since the last call to
                         !! calculate_surface_state, in units of deg C kg m-2.
end type thermo_var_ptrs

!> The ocean_internal_state structure contains pointers to all of the prognostic
!! variables allocated in MOM_variables.F90 and MOM.F90.  It is useful for
!! sending these variables for diagnostics, and in preparation for ensembles
!! later on.  All variables have the same names as the local (public) variables
!! they refer to in MOM.F90.
type, public :: ocean_internal_state
  real, pointer, dimension(:,:,:) :: &
    u => NULL(), v => NULL(), h => NULL()
  real, pointer, dimension(:,:,:) :: &
    uh => NULL(), vh => NULL(), &
    CAu => NULL(), CAv => NULL(), &
    PFu  => NULL(), PFv => NULL(), diffu => NULL(), diffv => NULL(), &
    T => NULL(), S => NULL(), &
    pbce => NULL(), u_accel_bt => NULL(), v_accel_bt => NULL(), &
    u_av => NULL(), v_av => NULL(), u_prev => NULL(), v_prev => NULL()
end type ocean_internal_state

!> The accel_diag_ptrs structure contains pointers to arrays with accelerations,
!! which can later be used for derived diagnostics, like energy balances.
type, public :: accel_diag_ptrs

! Each of the following fields has nz layers.
  real, pointer :: diffu(:,:,:) => NULL()    ! Accelerations due to along iso-
  real, pointer :: diffv(:,:,:) => NULL()    ! pycnal viscosity, in m s-2.
  real, pointer :: CAu(:,:,:) => NULL()      ! Coriolis and momentum advection
  real, pointer :: CAv(:,:,:) => NULL()      ! accelerations, in m s-2.
  real, pointer :: PFu(:,:,:) => NULL()      ! Accelerations due to pressure
  real, pointer :: PFv(:,:,:) => NULL()      ! forces, in m s-2.
  real, pointer :: du_dt_visc(:,:,:) => NULL()! Accelerations due to vertical
  real, pointer :: dv_dt_visc(:,:,:) => NULL()! viscosity, in m s-2.
  real, pointer :: du_dt_dia(:,:,:) => NULL()! Accelerations due to diapycnal
  real, pointer :: dv_dt_dia(:,:,:) => NULL()! mixing, in m s-2.
  real, pointer :: du_other(:,:,:) => NULL() ! Velocity changes due to any other
  real, pointer :: dv_other(:,:,:) => NULL() ! processes that are not due to any
                                             ! explicit accelerations, in m s-1.

  ! These accelerations are sub-terms included in the accelerations above.
  real, pointer :: gradKEu(:,:,:) => NULL()  ! gradKEu = - d/dx(u2), in m s-2.
  real, pointer :: gradKEv(:,:,:) => NULL()  ! gradKEv = - d/dy(u2), in m s-2.
  real, pointer :: rv_x_v(:,:,:) => NULL()   ! rv_x_v = rv * v at u, in m s-2.
  real, pointer :: rv_x_u(:,:,:) => NULL()   ! rv_x_u = rv * u at v, in m s-2.

end type accel_diag_ptrs

!> The cont_diag_ptrs structure contains pointers to arrays with transports,
!! which can later be used for derived diagnostics, like energy balances.
type, public :: cont_diag_ptrs

! Each of the following fields has nz layers.
  real, pointer :: uh(:,:,:) => NULL()    ! Resolved layer thickness fluxes,
  real, pointer :: vh(:,:,:) => NULL()    ! in m3 s-1 or kg s-1.
  real, pointer :: uhGM(:,:,:) => NULL()  ! Thickness diffusion induced
  real, pointer :: vhGM(:,:,:) => NULL()  ! volume fluxes in m3 s-1.

! Each of the following fields is found at nz+1 interfaces.
  real, pointer :: diapyc_vel(:,:,:) => NULL()! The net diapycnal velocity,

end type cont_diag_ptrs

!>   The vertvisc_type structure contains vertical viscosities, drag
!! coefficients, and related fields.
type, public :: vertvisc_type
  real :: Prandtl_turb       !< The Prandtl number for the turbulent diffusion
                             !! that is captured in Kd_turb.
  real, pointer, dimension(:,:) :: &
    bbl_thick_u => NULL(), & !< The bottom boundary layer thickness at the
                             !! u-points, in m.
    bbl_thick_v => NULL(), & !< The bottom boundary layer thickness at the
                             !! v-points, in m.
    kv_bbl_u => NULL(), &    !< The bottom boundary layer viscosity at the
                             !! u-points, in m2 s-1.
    kv_bbl_v => NULL(), &    !< The bottom boundary layer viscosity at the
                             !! v-points, in m2 s-1.
    ustar_BBL => NULL(), &   !< The turbulence velocity in the bottom boundary
                             !! layer at h points, in m s-1.
    TKE_BBL => NULL(), &     !< A term related to the bottom boundary layer
                             !! source of turbulent kinetic energy, currently
                             !! in units of m3 s-3, but will later be changed
                             !! to W m-2.
    taux_shelf => NULL(), &  !< The zonal stresses on the ocean under shelves, in Pa.
    tauy_shelf => NULL(), &  !< The meridional stresses on the ocean under shelves, in Pa.
    tbl_thick_shelf_u => NULL(), & !< Thickness of the viscous top boundary
                             !< layer under ice shelves at u-points, in m.
    tbl_thick_shelf_v => NULL(), & !< Thickness of the viscous top boundary
                             !< layer under ice shelves at v-points, in m.
    kv_tbl_shelf_u => NULL(), &  !< Viscosity in the viscous top boundary layer
                             !! under ice shelves at u-points, in m2 s-1.
    kv_tbl_shelf_v => NULL(), &  !< Viscosity in the viscous top boundary layer
                             !! under ice shelves at u-points, in m2 s-1.
    nkml_visc_u => NULL(), & !< The number of layers in the viscous surface
                             !! mixed layer at u-points (nondimensional).  This
                             !! is not an integer because there may be
                             !! fractional layers, and it is stored
                             !! in terms of layers, not depth, to facilitate
                             !! the movement of the viscous boundary layer with
                             !! the flow.
    nkml_visc_v => NULL(), & !< The number of layers in the viscous surface
                             !! mixed layer at v-points (nondimensional).
    MLD => NULL()            !< Instantaneous active mixing layer depth (H units).
  real, pointer, dimension(:,:,:) :: &
    Ray_u => NULL(), &  !< The Rayleigh drag velocity to be applied to each layer
                        !! at u-points, in m s-1.
    Ray_v => NULL(), &  !< The Rayleigh drag velocity to be applied to each layer
                        !! at v-points, in m s-1.
    Kd_extra_T => NULL(), & !< The extra diffusivity of temperature due to
                        !! double diffusion relative to the diffusivity of
                        !! density, in m2 s-1.
    Kd_extra_S => NULL(), & !< The extra diffusivity of salinity due to
                        !! double diffusion relative to the diffusivity of
                        !! density, in m2 s-1.
                        !   One of Kd_extra_T and Kd_extra_S is always 0.
                        ! Kd_extra_S is positive for salt fingering; Kd_extra_T
                        ! is positive for double diffusive convection.  These
                        ! are only allocated if DOUBLE_DIFFUSION is true.
    Kd_turb => NULL(), &!< The turbulent diapycnal diffusivity at the interfaces
                        !! between each layer, in m2 s-1.
    Kv_turb => NULL(), &!< The turbulent vertical viscosity at the interfaces
                        !! between each layer, in m2 s-1.
    TKE_turb => NULL()  !< The turbulent kinetic energy per unit mass defined
                        !! at the interfaces between each layer, in m2 s-2.
end type vertvisc_type

!> The BT_cont_type structure contains information about the summed layer
!! transports and how they will vary as the barotropic velocity is changed.
type, public :: BT_cont_type
  real, pointer, dimension(:,:) :: &
    FA_u_EE => NULL(), &  ! The FA_u_XX variables are the effective open face
    FA_u_E0 => NULL(), &  ! areas for barotropic transport through the zonal
    FA_u_W0 => NULL(), &  ! faces, all in H m, with the XX indicating where
    FA_u_WW => NULL(), &  ! the transport is from, with _EE drawing from points
                          ! far to the east, _E0 from points nearby from the
                          ! east, _W0 nearby from the west, and _WW from far to
                          ! the west.
    uBT_WW => NULL(), &   ! uBT_WW is the barotropic velocity, in m s-1, beyond
                          ! which the marginal open face area is FA_u_WW.
                          ! uBT_EE must be non-negative.
    uBT_EE => NULL(), &   ! uBT_EE is the barotropic velocity, in m s-1, beyond
                          ! which the marginal open face area is FA_u_EE.
                          ! uBT_EE must be non-positive.
    FA_v_NN => NULL(), &  ! The FA_v_XX variables are the effective open face
    FA_v_N0 => NULL(), &  ! areas for barotropic transport through the meridional
    FA_v_S0 => NULL(), &  ! faces, all in H m, with the XX indicating where
    FA_v_SS => NULL(), &  ! the transport is from, with _NN drawing from points
                          ! far to the north, _N0 from points nearby from the
                          ! north, _S0 nearby from the south, and _SS from far
                          ! to the south.
    vBT_SS => NULL(), &   ! vBT_SS is the barotropic velocity, in m s-1, beyond
                          ! which the marginal open face area is FA_v_SS.
                          ! vBT_SS must be non-negative.
    vBT_NN => NULL()      ! vBT_NN is the barotropic velocity, in m s-1, beyond
                          ! which the marginal open face area is FA_v_NN.
                          ! vBT_NN must be non-positive.
  real, pointer, dimension(:,:,:) :: &
    h_u => NULL(), &      ! An effective thickness at zonal faces, in H.
    h_v => NULL()         ! An effective thickness at meridional faces, in H.
  type(group_pass_type) :: pass_polarity_BT, pass_FA_uv ! For group halo updates
end type BT_cont_type

contains


!> This subroutine allocates the fields for the surface (return) properties of
!! the ocean model.  Unused fields are unallocated.
subroutine allocate_surface_state(sfc_state, G, use_temperature, do_integrals, &
                                  gas_fields_ocn)
  type(ocean_grid_type), intent(in)    :: G                !< ocean grid structure
  type(surface),         intent(inout) :: sfc_state        !< ocean surface state type to be allocated.
  logical,     optional, intent(in)    :: use_temperature  !< If true, allocate the space for thermodynamic variables.
  logical,     optional, intent(in)    :: do_integrals     !< If true, allocate the space for vertically integrated fields.
  type(coupler_1d_bc_type), &
               optional, intent(in)    :: gas_fields_ocn   !< If present, this type describes the ocean
                                              !! ocean and surface-ice fields that will participate
                                              !! in the calculation of additional gas or other
                                              !! tracer fluxes, and can be used to spawn related
                                              !! internal variables in the ice model.

  logical :: use_temp, alloc_integ
  integer :: is, ie, js, je, isd, ied, jsd, jed
  integer :: isdB, iedB, jsdB, jedB

  is  = G%isc ; ie  = G%iec ; js  = G%jsc ; je  = G%jec
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  isdB = G%isdB ; iedB = G%iedB; jsdB = G%jsdB ; jedB = G%jedB

  use_temp = .true. ; if (present(use_temperature)) use_temp = use_temperature
  alloc_integ = .true. ; if (present(do_integrals)) alloc_integ = do_integrals

  if (sfc_state%arrays_allocated) return

  if (use_temp) then
    allocate(sfc_state%SST(isd:ied,jsd:jed)) ; sfc_state%SST(:,:) = 0.0
    allocate(sfc_state%SSS(isd:ied,jsd:jed)) ; sfc_state%SSS(:,:) = 0.0
  else
    allocate(sfc_state%sfc_density(isd:ied,jsd:jed)) ; sfc_state%sfc_density(:,:) = 0.0
  endif
  allocate(sfc_state%sea_lev(isd:ied,jsd:jed)) ; sfc_state%sea_lev(:,:) = 0.0
  allocate(sfc_state%Hml(isd:ied,jsd:jed)) ; sfc_state%Hml(:,:) = 0.0
  allocate(sfc_state%u(IsdB:IedB,jsd:jed)) ; sfc_state%u(:,:) = 0.0
  allocate(sfc_state%v(isd:ied,JsdB:JedB)) ; sfc_state%v(:,:) = 0.0

  if (alloc_integ) then
    ! Allocate structures for the vertically integrated ocean_mass, ocean_heat,
    ! and ocean_salt.
    allocate(sfc_state%ocean_mass(isd:ied,jsd:jed)) ; sfc_state%ocean_mass(:,:) = 0.0
    if (use_temp) then
      allocate(sfc_state%ocean_heat(isd:ied,jsd:jed)) ; sfc_state%ocean_heat(:,:) = 0.0
      allocate(sfc_state%ocean_salt(isd:ied,jsd:jed)) ; sfc_state%ocean_salt(:,:) = 0.0
    endif
    allocate(sfc_state%salt_deficit(isd:ied,jsd:jed)) ; sfc_state%salt_deficit(:,:) = 0.0
  endif

  if (present(gas_fields_ocn)) &
    call coupler_type_spawn(gas_fields_ocn, sfc_state%tr_fields, &
                            (/isd,is,ie,ied/), (/jsd,js,je,jed/), as_needed=.true.)

  sfc_state%arrays_allocated = .true.

end subroutine allocate_surface_state

!> This subroutine deallocates the elements of a surface state type.
subroutine deallocate_surface_state(sfc_state)
  type(surface),         intent(inout) :: sfc_state        !< ocean surface state type to be deallocated.

  if (.not.sfc_state%arrays_allocated) return

  if (allocated(sfc_state%SST)) deallocate(sfc_state%SST)
  if (allocated(sfc_state%SSS)) deallocate(sfc_state%SSS)
  if (allocated(sfc_state%sfc_density)) deallocate(sfc_state%sfc_density)
  if (allocated(sfc_state%sea_lev)) deallocate(sfc_state%sea_lev)
  if (allocated(sfc_state%Hml)) deallocate(sfc_state%Hml)
  if (allocated(sfc_state%u)) deallocate(sfc_state%u)
  if (allocated(sfc_state%v)) deallocate(sfc_state%v)
  if (allocated(sfc_state%ocean_mass)) deallocate(sfc_state%ocean_mass)
  if (allocated(sfc_state%ocean_heat)) deallocate(sfc_state%ocean_heat)
  if (allocated(sfc_state%ocean_salt)) deallocate(sfc_state%ocean_salt)
  if (allocated(sfc_state%salt_deficit)) deallocate(sfc_state%salt_deficit)

  call coupler_type_destructor(sfc_state%tr_fields)

  sfc_state%arrays_allocated = .false.

end subroutine deallocate_surface_state

!> alloc_BT_cont_type allocates the arrays contained within a BT_cont_type and
!! initializes them to 0.
subroutine alloc_BT_cont_type(BT_cont, G, alloc_faces)
  type(BT_cont_type),    pointer    :: BT_cont
  type(ocean_grid_type), intent(in) :: G    !< The ocean's grid structure
  logical,     optional, intent(in) :: alloc_faces

  integer :: isd, ied, jsd, jed, IsdB, IedB, JsdB, JedB
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  IsdB = G%IsdB ; IedB = G%IedB ; JsdB = G%JsdB ; JedB = G%JedB

  if (associated(BT_cont)) call MOM_error(FATAL, &
    "alloc_BT_cont_type called with an associated BT_cont_type pointer.")

  allocate(BT_cont)
  allocate(BT_cont%FA_u_WW(IsdB:IedB,jsd:jed)) ; BT_cont%FA_u_WW(:,:) = 0.0
  allocate(BT_cont%FA_u_W0(IsdB:IedB,jsd:jed)) ; BT_cont%FA_u_W0(:,:) = 0.0
  allocate(BT_cont%FA_u_E0(IsdB:IedB,jsd:jed)) ; BT_cont%FA_u_E0(:,:) = 0.0
  allocate(BT_cont%FA_u_EE(IsdB:IedB,jsd:jed)) ; BT_cont%FA_u_EE(:,:) = 0.0
  allocate(BT_cont%uBT_WW(IsdB:IedB,jsd:jed))  ; BT_cont%uBT_WW(:,:) = 0.0
  allocate(BT_cont%uBT_EE(IsdB:IedB,jsd:jed))  ; BT_cont%uBT_EE(:,:) = 0.0

  allocate(BT_cont%FA_v_SS(isd:ied,JsdB:JedB)) ; BT_cont%FA_v_SS(:,:) = 0.0
  allocate(BT_cont%FA_v_S0(isd:ied,JsdB:JedB)) ; BT_cont%FA_v_S0(:,:) = 0.0
  allocate(BT_cont%FA_v_N0(isd:ied,JsdB:JedB)) ; BT_cont%FA_v_N0(:,:) = 0.0
  allocate(BT_cont%FA_v_NN(isd:ied,JsdB:JedB)) ; BT_cont%FA_v_NN(:,:) = 0.0
  allocate(BT_cont%vBT_SS(isd:ied,JsdB:JedB))  ; BT_cont%vBT_SS(:,:) = 0.0
  allocate(BT_cont%vBT_NN(isd:ied,JsdB:JedB))  ; BT_cont%vBT_NN(:,:) = 0.0

  if (present(alloc_faces)) then ; if (alloc_faces) then
    allocate(BT_cont%h_u(IsdB:IedB,jsd:jed,1:G%ke)) ; BT_cont%h_u(:,:,:) = 0.0
    allocate(BT_cont%h_v(isd:ied,JsdB:JedB,1:G%ke)) ; BT_cont%h_v(:,:,:) = 0.0
  endif ; endif

end subroutine alloc_BT_cont_type

!> dealloc_BT_cont_type deallocates the arrays contained within a BT_cont_type.
subroutine dealloc_BT_cont_type(BT_cont)
  type(BT_cont_type), pointer :: BT_cont

  if (.not.associated(BT_cont)) return

  deallocate(BT_cont%FA_u_WW) ; deallocate(BT_cont%FA_u_W0)
  deallocate(BT_cont%FA_u_E0) ; deallocate(BT_cont%FA_u_EE)
  deallocate(BT_cont%uBT_WW)  ; deallocate(BT_cont%uBT_EE)

  deallocate(BT_cont%FA_v_SS) ; deallocate(BT_cont%FA_v_S0)
  deallocate(BT_cont%FA_v_N0) ; deallocate(BT_cont%FA_v_NN)
  deallocate(BT_cont%vBT_SS)  ; deallocate(BT_cont%vBT_NN)

  if (associated(BT_cont%h_u)) deallocate(BT_cont%h_u)
  if (associated(BT_cont%h_v)) deallocate(BT_cont%h_v)

  deallocate(BT_cont)

end subroutine dealloc_BT_cont_type

!> MOM_thermovar_chksum does diagnostic checksums on various elements of a
!! thermo_var_ptrs type for debugging.
subroutine MOM_thermovar_chksum(mesg, tv, G)
  character(len=*),                    intent(in) :: mesg
  type(thermo_var_ptrs),               intent(in) :: tv   !< A structure pointing to various thermodynamic variables
  type(ocean_grid_type),               intent(in) :: G    !< The ocean's grid structure
!   This subroutine writes out chksums for the model's basic state variables.
! Arguments: mesg - A message that appears on the chksum lines.
!  (in)      u - Zonal velocity, in m s-1.
!  (in)      v - Meridional velocity, in m s-1.
!  (in)      h - Layer thickness, in m.
!  (in)      uh - Volume flux through zonal faces = u*h*dy, m3 s-1.
!  (in)      vh - Volume flux through meridional faces = v*h*dx, in m3 s-1.
!  (in)      G - The ocean's grid structure.
  integer :: is, ie, js, je, nz
  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  ! Note that for the chksum calls to be useful for reproducing across PE
  ! counts, there must be no redundant points, so all variables use is..ie
  ! and js...je as their extent.
  if (associated(tv%T)) &
    call hchksum(tv%T, mesg//" tv%T",G%HI)
  if (associated(tv%S)) &
    call hchksum(tv%S, mesg//" tv%S",G%HI)
  if (associated(tv%frazil)) &
    call hchksum(tv%frazil, mesg//" tv%frazil",G%HI)
  if (associated(tv%salt_deficit)) &
    call hchksum(tv%salt_deficit, mesg//" tv%salt_deficit",G%HI)
  if (associated(tv%TempxPmE)) &
    call hchksum(tv%TempxPmE, mesg//" tv%TempxPmE",G%HI)
end subroutine MOM_thermovar_chksum

end module MOM_variables
