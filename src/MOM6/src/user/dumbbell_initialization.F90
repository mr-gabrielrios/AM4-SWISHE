module dumbbell_initialization

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_domains, only : sum_across_PEs
use MOM_dyn_horgrid, only : dyn_horgrid_type
use MOM_error_handler, only : MOM_mesg, MOM_error, FATAL, is_root_pe
use MOM_file_parser, only : get_param, param_file_type
use MOM_get_input, only : directories
use MOM_grid, only : ocean_grid_type
use MOM_sponge, only : set_up_sponge_field, initialize_sponge, sponge_CS
use MOM_tracer_registry, only : tracer_registry_type
use MOM_variables, only : thermo_var_ptrs
use MOM_verticalGrid, only : verticalGrid_type
use MOM_EOS, only : calculate_density, calculate_density_derivs, EOS_type
use regrid_consts, only : coordinateMode, DEFAULT_COORDINATE_MODE
use regrid_consts, only : REGRIDDING_LAYER, REGRIDDING_ZSTAR
use regrid_consts, only : REGRIDDING_RHO, REGRIDDING_SIGMA
use MOM_ALE_sponge,    only : ALE_sponge_CS, set_up_ALE_sponge_field, initialize_ALE_sponge

implicit none ; private

#include <MOM_memory.h>

character(len=40) :: mdl = "dumbbell_initialization" ! This module's name.

! -----------------------------------------------------------------------------
! The following routines are visible to the outside world
! -----------------------------------------------------------------------------
public dumbbell_initialize_topography
public dumbbell_initialize_thickness
public dumbbell_initialize_temperature_salinity
public dumbbell_initialize_sponges
! -----------------------------------------------------------------------------
! This module contains the following routines
! -----------------------------------------------------------------------------
contains

!> Initialization of topography.
subroutine dumbbell_initialize_topography ( D, G, param_file, max_depth )
  ! Arguments
  type(dyn_horgrid_type),             intent(in)  :: G !< The dynamic horizontal grid type
  real, dimension(G%isd:G%ied,G%jsd:G%jed), &
                                      intent(out) :: D !< Ocean bottom depth in m
  type(param_file_type),              intent(in)  :: param_file !< Parameter file structure
  real,                               intent(in)  :: max_depth  !< Maximum depth of model in m

  ! Local variables
  integer   :: i, j
  real      :: x, y, delta, dblen, dbfrac

  call get_param(param_file, mdl,"DUMBBELL_LEN",dblen, &
                'Lateral Length scale for dumbbell.',&
                 units='k', default=600., do_not_log=.false.)
  call get_param(param_file, mdl,"DUMBBELL_FRACTION",dbfrac, &
                'Meridional fraction for narrow part of dumbbell.',&
                 units='nondim', default=0.5, do_not_log=.false.)

  if (G%x_axis_units == 'm') then
    dblen=dblen*1.e3
  endif

 do i=G%isc,G%iec
    do j=G%jsc,G%jec
      ! Compute normalized zonal coordinates (x,y=0 at center of domain)
      x = ( G%geoLonT(i,j) ) / dblen
      y = ( G%geoLatT(i,j)  ) / G%len_lat
      D(i,j)=G%max_depth
      if ((x>=-0.25 .and. x<=0.25) .and. (y <= -0.5*dbfrac .or. y >= 0.5*dbfrac)) then
        D(i,j) = 0.0
      endif
    enddo
  enddo

end subroutine dumbbell_initialize_topography

!> Initialization of thicknesses.
!! This subroutine initializes the layer thicknesses to be uniform.
subroutine dumbbell_initialize_thickness ( h, G, GV, param_file, just_read_params)
  type(ocean_grid_type),   intent(in)  :: G           !< The ocean's grid structure.
  type(verticalGrid_type), intent(in)  :: GV          !< The ocean's vertical grid structure.
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)), &
                           intent(out) :: h           !< The thickness that is being initialized, in m.
  type(param_file_type),   intent(in)  :: param_file  !< A structure indicating the open file
                                                      !! to parse for model parameter values.
  logical,       optional, intent(in)  :: just_read_params !< If present and true, this call will
                                                      !! only read parameters without changing h.

  real :: e0(SZK_(G)+1)   ! The resting interface heights, in m, usually !
                          ! negative because it is positive upward.      !
  real :: eta1D(SZK_(G)+1)! Interface height relative to the sea surface !
                          ! positive upward, in m.                       !
  integer :: i, j, k, is, ie, js, je, nz
  real    :: x
  real    :: delta_h
  real    :: min_thickness, S_surf, S_range, S_ref, S_light, S_dense
  character(len=20) :: verticalCoordinate
  logical :: just_read    ! If true, just read parameters but set nothing.  character(len=20) :: verticalCoordinate

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  just_read = .false. ; if (present(just_read_params)) just_read = just_read_params

  if (.not.just_read) &
    call MOM_mesg("MOM_initialization.F90, initialize_thickness_uniform: setting thickness")

  call get_param(param_file, mdl,"MIN_THICKNESS",min_thickness, &
                'Minimum thickness for layer',&
                 units='m', default=1.0e-3, do_not_log=just_read)
  call get_param(param_file, mdl,"REGRIDDING_COORDINATE_MODE",verticalCoordinate, &
                 default=DEFAULT_COORDINATE_MODE, do_not_log=just_read)

  ! WARNING: this routine specifies the interface heights so that the last layer
  !          is vanished, even at maximum depth. In order to have a uniform
  !          layer distribution, use this line of code within the loop:
  !          e0(k) = -G%max_depth * real(k-1) / real(nz)
  !          To obtain a thickness distribution where the last layer is
  !          vanished and the other thicknesses uniformly distributed, use:
  !          e0(k) = -G%max_depth * real(k-1) / real(nz-1)
  !do k=1,nz+1
  !  e0(k) = -G%max_depth * real(k-1) / real(nz)
  !enddo

  select case ( coordinateMode(verticalCoordinate) )

  case ( REGRIDDING_LAYER, REGRIDDING_RHO ) ! Initial thicknesses for isopycnal coordinates
    call get_param(param_file, mdl,"INITIAL_SSS", S_surf, default=34., do_not_log=.true.)
    call get_param(param_file, mdl,"INITIAL_S_RANGE", S_range, default=2., do_not_log=.true.)
    call get_param(param_file, mdl, "S_REF", S_ref, default=35.0, do_not_log=.true.)
    call get_param(param_file, mdl, "TS_RANGE_S_LIGHT", S_light, default = S_Ref, do_not_log=.true.)
    call get_param(param_file, mdl, "TS_RANGE_S_DENSE", S_dense, default = S_Ref, do_not_log=.true.)
    if (just_read) return ! All run-time parameters have been read, so return.

    do K=1,nz+1
      ! Salinity of layer k is S_light + (k-1)/(nz-1) * (S_dense - S_light)
      ! Salinity of interface K is S_light + (K-3/2)/(nz-1) * (S_dense - S_light)
      ! Salinity at depth z should be S(z) = S_surf - S_range * z/max_depth
      ! Equating: S_surf - S_range * z/max_depth = S_light + (K-3/2)/(nz-1) * (S_dense - S_light)
      ! Equating: - S_range * z/max_depth = S_light - S_surf + (K-3/2)/(nz-1) * (S_dense - S_light)
      ! Equating: z/max_depth = - ( S_light - S_surf + (K-3/2)/(nz-1) * (S_dense - S_light) ) / S_range
      e0(K) = - G%max_depth * ( ( S_light  - S_surf ) + ( S_dense - S_light ) * ( (real(K)-1.5) / real(nz-1) ) ) / S_range
      e0(K) = nint(2048.*e0(K))/2048. ! Force round numbers ... the above expression has irrational factors ...
      e0(K) = min(real(1-K)*GV%Angstrom_z, e0(K)) ! Bound by surface
      e0(K) = max(-G%max_depth, e0(K)) ! Bound by bottom
    enddo
    do j=js,je ; do i=is,ie
      eta1D(nz+1) = -1.0*G%bathyT(i,j)
      do k=nz,1,-1
        eta1D(k) = e0(k)
        if (eta1D(k) < (eta1D(k+1) + GV%Angstrom_z)) then
          eta1D(k) = eta1D(k+1) + GV%Angstrom_z
          h(i,j,k) = GV%Angstrom_z
        else
          h(i,j,k) = eta1D(k) - eta1D(k+1)
        endif
      enddo
    enddo ; enddo

  case ( REGRIDDING_ZSTAR )                       ! Initial thicknesses for z coordinates
    if (just_read) return ! All run-time parameters have been read, so return.
    do j=js,je ; do i=is,ie
      eta1D(nz+1) = -1.0*G%bathyT(i,j)
      do k=nz,1,-1
        eta1D(k) = -G%max_depth * real(k-1) / real(nz)
        if (eta1D(k) < (eta1D(k+1) + min_thickness)) then
          eta1D(k) = eta1D(k+1) + min_thickness
          h(i,j,k) = min_thickness
        else
          h(i,j,k) = eta1D(k) - eta1D(k+1)
        endif
      enddo
    enddo ; enddo

  case ( REGRIDDING_SIGMA )             ! Initial thicknesses for sigma coordinates
    if (just_read) return ! All run-time parameters have been read, so return.
    do j=js,je ; do i=is,ie
      delta_h = G%bathyT(i,j) / dfloat(nz)
      h(i,j,:) = delta_h
    end do ; end do

end select

end subroutine dumbbell_initialize_thickness

!> Initial values for temperature and salinity
subroutine dumbbell_initialize_temperature_salinity ( T, S, h, G, GV, param_file, &
                                                  eqn_of_state, just_read_params)
  type(ocean_grid_type),                     intent(in)  :: G !< Ocean grid structure
  type(verticalGrid_type),                   intent(in) :: GV !< Vertical grid structure
  real, dimension(SZI_(G),SZJ_(G), SZK_(G)), intent(out) :: T !< Potential temperature (degC)
  real, dimension(SZI_(G),SZJ_(G), SZK_(G)), intent(out) :: S !< Salinity (ppt)
  real, dimension(SZI_(G),SZJ_(G), SZK_(G)), intent(in)  :: h !< Layer thickness (m or Pa)
  type(param_file_type),                     intent(in)  :: param_file !< Parameter file structure
  type(EOS_type),                            pointer     :: eqn_of_state !< Equation of state structure
  logical,       optional, intent(in)  :: just_read_params !< If present and true, this call will
                                                      !! only read parameters without changing h.

  ! Local variables
  integer :: i, j, k, is, ie, js, je, nz, k_light
  real    :: xi0, xi1, dxi, r, S_surf, T_surf, S_range, T_range
  real    :: x, y, dblen
  real    :: T_ref, T_Light, T_Dense, S_ref, S_Light, S_Dense, a1, frac_dense, k_frac, res_rat
  logical :: just_read    ! If true, just read parameters but set nothing.
  character(len=20) :: verticalCoordinate, density_profile

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  just_read = .false. ; if (present(just_read_params)) just_read = just_read_params

  T_surf = 20.0

  call get_param(param_file, mdl, "REGRIDDING_COORDINATE_MODE", verticalCoordinate, &
                 default=DEFAULT_COORDINATE_MODE, do_not_log=just_read)
  call get_param(param_file, mdl,"INITIAL_DENSITY_PROFILE", density_profile, &
                 'Initial profile shape. Valid values are "linear", "parabolic"\n'// &
                 'and "exponential".', default='linear', do_not_log=just_read)
  call get_param(param_file, mdl,"DUMBBELL_SREF", S_surf, &
                 'DUMBBELL REFERENCE SALINITY', units='1e-3', default=34., do_not_log=just_read)
  call get_param(param_file, mdl,"DUMBBELL_S_RANGE", S_range, &
                 'DUMBBELL salinity range (right-left)', units='1e-3', &
                 default=2., do_not_log=just_read)
  call get_param(param_file, mdl,"DUMBBELL_LEN",dblen, &
                'Lateral Length scale for dumbbell ',&
                 units='k', default=600., do_not_log=just_read)

  if (G%x_axis_units == 'm') then
    dblen=dblen*1.e3
  endif

  do j=G%jsc,G%jec
    do i=G%isc,G%iec
    ! Compute normalized zonal coordinates (x,y=0 at center of domain)
      x = ( G%geoLonT(i,j) ) / dblen
      do k=1,nz
        T(i,j,k)=T_surf
      enddo
      if (x>=0. ) then
        do k=1,nz
          S(i,j,k)=S_surf + 0.5*S_range
        enddo
      endif
      if (x<0. ) then
        do k=1,nz
          S(i,j,k)=S_surf - 0.5*S_range
        enddo
      endif

    enddo
  enddo

end subroutine dumbbell_initialize_temperature_salinity

!> Initialize the restoring sponges for the dense water experiment
subroutine dumbbell_initialize_sponges(G, GV, tv, param_file, use_ALE, CSp, ACSp)
  type(ocean_grid_type),   intent(in) :: G !< Horizontal grid control structure
  type(verticalGrid_type), intent(in) :: GV !< Vertical grid control structure
  type(thermo_var_ptrs),   intent(in) :: tv !< Thermodynamic variables
  type(param_file_type),   intent(in) :: param_file !< Parameter file structure
  logical,                 intent(in) :: use_ALE !< ALE flag
  type(sponge_CS),         pointer    :: CSp !< Layered sponge control structure pointer
  type(ALE_sponge_CS),     pointer    :: ACSp !< ALE sponge control structure pointer

  real :: sponge_time_scale

  real, dimension(SZI_(G),SZJ_(G)) :: Idamp ! inverse damping timescale
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)) :: h, T, S ! sponge thicknesses, temp and salt
  real, dimension(SZK_(GV)+1) :: e0, eta1D ! interface positions for ALE sponge

  integer :: i, j, k, nz
  real :: x, zi, zmid, dist, min_thickness, dblen
  real :: mld, S_ref, S_range, S_dense, T_ref, sill_height
  call get_param(param_file, mdl,"DUMBBELL_LEN",dblen, &
                'Lateral Length scale for dumbbell ',&
                 units='k', default=600., do_not_log=.true.)

  if (G%x_axis_units == 'm') then
    dblen=dblen*1.e3
  endif

  nz = GV%ke

  call get_param(param_file, mdl, "DUMBBELL_SPONGE_TIME_SCALE", sponge_time_scale, &
       "The time scale in the reservoir for restoring. If zero, the sponge is disabled.", &
       units="s", default=0.)
  call get_param(param_file, mdl, "DUMBBELL_SREF", S_ref, do_not_log=.true.)
  call get_param(param_file, mdl, "DUMBBELL_S_RANGE", S_range, do_not_log=.true.)
  call get_param(param_file, mdl,"MIN_THICKNESS",min_thickness, &
                'Minimum thickness for layer',&
                 units='m', default=1.0e-3, do_not_log=.true.)

  ! no active sponges
  if (sponge_time_scale <= 0.) return

  ! everywhere is initially unsponged
  Idamp(:,:) = 0.0

  do j = G%jsc, G%jec
    do i = G%isc,G%iec
      if (G%mask2dT(i,j) > 0.) then
        ! nondimensional x position
        x = (G%geoLonT(i,j) ) / dblen
        if (x > 0.25 .or. x < -0.25) then
          ! scale restoring by depth into sponge
          Idamp(i,j) = 1. / sponge_time_scale
        endif
      endif
    enddo
  enddo

  if (use_ALE) then
    ! construct a uniform grid for the sponge
    do j=G%jsc,G%jec ; do i=G%isc,G%iec
      eta1D(nz+1) = -1.0*G%bathyT(i,j)
      do k=nz,1,-1
        eta1D(k) = -G%max_depth * real(k-1) / real(nz)
        if (eta1D(k) < (eta1D(k+1) + min_thickness)) then
          eta1D(k) = eta1D(k+1) + min_thickness
          h(i,j,k) = min_thickness
        else
          h(i,j,k) = eta1D(k) - eta1D(k+1)
        endif
      enddo
    enddo ; enddo

    call initialize_ALE_sponge(Idamp, G, param_file, ACSp, h, nz)

    ! construct temperature and salinity for the sponge
    ! start with initial condition
    S(:,:,:) = 0.0

    do j=G%jsc,G%jec
      do i=G%isc,G%iec

      ! Compute normalized zonal coordinates (x,y=0 at center of domain)
         x = ( G%geoLonT(i,j) ) / dblen
         if (x>=0.25 ) then
           do k=1,nz
             S(i,j,k)=S_ref + 0.5*S_range
           enddo
         endif
         if (x<=-0.25 ) then
           do k=1,nz
             S(i,j,k)=S_ref - 0.5*S_range
           enddo
         endif
!         if (j.eq.G%jsc) print *,'i,Sponge S= ',i,S(i,1,1)
       enddo

     enddo
  endif

  if (associated(tv%S)) call set_up_ALE_sponge_field(S, G, tv%S, ACSp)

end subroutine dumbbell_initialize_sponges

!> \namespace dumbbell_initialization
!!
!! The module configures the model for the idealized dumbbell
!! test case.
end module dumbbell_initialization
