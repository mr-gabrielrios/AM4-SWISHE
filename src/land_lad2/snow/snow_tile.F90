!***********************************************************************
!*                   GNU Lesser General Public License
!*
!* This file is part of the GFDL Land Model 4 (LM4).
!*
!* LM4 is free software: you can redistribute it and/or modify it under
!* the terms of the GNU Lesser General Public License as published by
!* the Free Software Foundation, either version 3 of the License, or (at
!* your option) any later version.
!*
!* LM4 is distributed in the hope that it will be useful, but WITHOUT
!* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
!* FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
!* for more details.
!*
!* You should have received a copy of the GNU Lesser General Public
!* License along with LM4.  If not, see <http://www.gnu.org/licenses/>.
!***********************************************************************
module snow_tile_mod
#include <fms_platform.h>

use mpp_mod, only: input_nml_file
use fms_mod, only : check_nml_error, stdlog
use constants_mod,only: PI,tfreeze, hlf
use land_constants_mod, only : NBANDS
use land_tile_selectors_mod, only : tile_selector_type
use land_data_mod, only : log_version, lnd

implicit none
private

! ==== public interfaces =====================================================
public :: snow_tile_type

public :: new_snow_tile, delete_snow_tile
public :: snow_tiles_can_be_merged, merge_snow_tiles
public :: snow_is_selected
public :: get_snow_tile_tag
public :: snow_tile_stock_pe
public :: snow_tile_heat
public :: snow_active

public :: read_snow_data_namelist

public :: snow_data_thermodynamics
public :: snow_data_hydraulics
public :: snow_data_area
public :: snow_radiation
public :: snow_roughness
! ==== end of public interfaces ==============================================
interface new_snow_tile
   module procedure snow_tile_ctor
   module procedure snow_tile_copy_ctor
end interface


! ==== module constants ======================================================
character(len=*), parameter :: module_name = 'snow_tile_mod'
#include "../shared/version_variable.inc"

integer, parameter, public :: max_lev = 10

! from the modis brdf/albedo product users guide:
real, parameter :: g_iso  = 1.
real, parameter :: g_vol  = 0.189184
real, parameter :: g_geo  = -1.377622
real, parameter :: g0_iso = 1.0
real, parameter :: g1_iso = 0.0
real, parameter :: g2_iso = 0.0
real, parameter :: g0_vol = -0.007574
real, parameter :: g1_vol = -0.070987
real, parameter :: g2_vol =  0.307588
real, parameter :: g0_geo = -1.284909
real, parameter :: g1_geo = -0.166314
real, parameter :: g2_geo =  0.041840

! range of temperatures for ramp between "warm" and "cold" albedo
real, parameter :: t_range = 10.0 ! degK

real, parameter :: deg2rad = PI/180.0

! ==== types =================================================================

type :: snow_tile_type
   integer :: tag ! kind of the tile
   real, allocatable :: wl(:)
   real, allocatable :: ws(:)
   real, allocatable :: T(:)
   real, allocatable :: e(:), f(:)
end type snow_tile_type

! ==== module data ===========================================================
logical, public :: use_brdf ! not protected because it is set in snow.F90

!---- namelist ---------------------------------------------------------------
logical :: use_mcm_masking       = .false.   ! MCM snow mask fn
real    :: w_sat                 = 670.
real    :: psi_sat               = -0.06
real    :: k_sat                 = 0.02
real    :: chb                   = 3.5
real    :: thermal_cond_ref      = 0.3
real    :: depth_crit            = 0.0167
real    :: z0_momentum           = 0.001
real    :: refl_snow_max_dir(NBANDS) = (/ 0.8,  0.8  /) ! reset to 0.6 for MCM
real    :: refl_snow_max_dif(NBANDS) = (/ 0.8,  0.8  /) ! reset to 0.6 for MCM
real    :: refl_snow_min_dir(NBANDS) = (/ 0.65, 0.65 /) ! reset to 0.45 for MCM
real    :: refl_snow_min_dif(NBANDS) = (/ 0.65, 0.65 /) ! reset to 0.45 for MCM
real    :: emis_snow_max         = 0.95      ! reset to 1 for MCM
real    :: emis_snow_min         = 0.90      ! reset to 1 for MCM
real    :: k_over_B              = 2         ! reset to 0 for MCM
integer :: num_l                 = 3         ! number of snow levels
real    :: dz(max_lev)           = (/0.1,0.8,0.1,0.,0.,0.,0.,0.,0.,0./)
                                              ! rel. thickness of model layers,
                                              ! from top down
real, protected, public :: &
   cpw = 1952.0, &  ! specific heat of water vapor at constant pressure
   clw = 4218.0, &  ! specific heat of water (liquid)
   csw = 2106.0     ! specific heat of water (ice)
real    :: mc_fict = 10. * 4218 ! additional (fictitious) soil heat capacity (for numerical stability?).
! from analysis of MODIS data (ignoring temperature dependence):
real :: f_iso_cold(NBANDS) = (/ 0.354, 0.530 /)
real :: f_vol_cold(NBANDS) = (/ 0.200, 0.252 /)
real :: f_geo_cold(NBANDS) = (/ 0.054, 0.064 /)
real :: f_iso_warm(NBANDS) = (/ 0.354, 0.530 /)
real :: f_vol_warm(NBANDS) = (/ 0.200, 0.252 /)
real :: f_geo_warm(NBANDS) = (/ 0.054, 0.064 /)

logical :: distinct_snow_on_glacier = .FALSE. ! if TRUE, the following parameters define
           ! reflectance of snow on glaciers, otherwise snow reflectance does not depend
           ! on the underlying surface (except overlap).
real :: f_iso_cold_on_glacier(NBANDS) = (/ 0.354, 0.530 /)
real :: f_vol_cold_on_glacier(NBANDS) = (/ 0.200, 0.252 /)
real :: f_geo_cold_on_glacier(NBANDS) = (/ 0.054, 0.064 /)
real :: f_iso_warm_on_glacier(NBANDS) = (/ 0.354, 0.530 /)
real :: f_vol_warm_on_glacier(NBANDS) = (/ 0.200, 0.252 /)
real :: f_geo_warm_on_glacier(NBANDS) = (/ 0.054, 0.064 /)
real :: refl_snow_max_dir_on_glacier(NBANDS) = (/ 0.8,  0.8  /) ! reset to 0.6 for MCM
real :: refl_snow_max_dif_on_glacier(NBANDS) = (/ 0.8,  0.8  /) ! reset to 0.6 for MCM
real :: refl_snow_min_dir_on_glacier(NBANDS) = (/ 0.65, 0.65 /) ! reset to 0.45 for MCM
real :: refl_snow_min_dif_on_glacier(NBANDS) = (/ 0.65, 0.65 /) ! reset to 0.45 for MCM
! boundaries of the boxes where the snow-on-glacier parameters are applied: by
! default all boxes are empty, except first (initialized later) which covers the
! entire Earth.
integer, parameter :: n_boxes = 2
real, dimension(n_boxes) :: box_W=0.0, box_E=0.0, box_S=+1.0, box_N=-1.0

namelist /snow_data_nml/use_mcm_masking,    w_sat,                 &
     psi_sat,                k_sat,                 &
     chb,                                           &
     thermal_cond_ref,       depth_crit,            &
     z0_momentum,                                   &
     f_iso_cold, f_vol_cold, f_geo_cold, &
     f_iso_warm, f_vol_warm, f_geo_warm, &
     refl_snow_max_dir, refl_snow_min_dir,   &
     refl_snow_max_dif, refl_snow_min_dif,   &
     emis_snow_max,          emis_snow_min, &
     k_over_B, &
     num_l, dz, cpw, clw, csw, mc_fict, &
! snow radiative parameters on glacier
     distinct_snow_on_glacier, &
     f_iso_cold_on_glacier, f_vol_cold_on_glacier, f_geo_cold_on_glacier, &
     f_iso_warm_on_glacier, f_vol_warm_on_glacier, f_geo_warm_on_glacier, &
     refl_snow_max_dir_on_glacier,    refl_snow_min_dir_on_glacier,   &
     refl_snow_max_dif_on_glacier,    refl_snow_min_dif_on_glacier,   &
     box_W, box_E, box_S, box_N

!---- end of namelist --------------------------------------------------------

contains ! -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

! ============================================================================
subroutine read_snow_data_namelist(snow_num_l, snow_dz, snow_mc_fict)
  integer, intent(out) :: snow_num_l
  real,    intent(out) :: snow_dz(:)
  real,    intent(out) :: snow_mc_fict

  ! ---- local vars
  integer :: unit         ! unit for namelist i/o
  integer :: io           ! i/o status for the namelist
  integer :: ierr         ! error code, returned by i/o routines

  call log_version(version, module_name, &
  __FILE__)
  ! set default values for the first box: it covers the whole Earth unless
  ! set otherwise in the namelist.
  box_W(1)=-180.0; box_E(1)=180.0; box_S(1)=-90.0; box_N(1)=90.0

  read (input_nml_file, nml=snow_data_nml, iostat=io)
  ierr = check_nml_error(io, 'snow_data_nml')
  unit=stdlog()
  write(unit, nml=snow_data_nml)

  ! initialize global module data here

  ! set up output arguments
  snow_num_l = num_l
  snow_dz    = dz
  snow_mc_fict = mc_fict

  ! convert box coordinates to radian
  box_W = box_W*deg2rad; box_E = box_E*deg2rad
  box_S = box_S*deg2rad; box_N = box_N*deg2rad
end subroutine read_snow_data_namelist

! ============================================================================
function snow_tile_ctor(tag) result(ptr)
  type(snow_tile_type), pointer :: ptr ! return value
  integer, optional, intent(in) :: tag ! kind of tile

  allocate(ptr)
  ptr%tag = 0 ; if(present(tag)) ptr%tag = tag
  ! allocate storage for tile data
  allocate(ptr%ws(num_l))
  allocate(ptr%wl(num_l))
  allocate(ptr%T(num_l))
  allocate(ptr%e(num_l))
  allocate(ptr%f(num_l))

end function snow_tile_ctor

! ============================================================================
function snow_tile_copy_ctor(snow) result(ptr)
  type(snow_tile_type), pointer :: ptr ! return value
  type(snow_tile_type), intent(in) :: snow ! tile to copy

  allocate(ptr)
  ! copy all non-pointer members
  ptr = snow
  ! no need to allocate storage for allocatable components of the type, because
  ! F2003 takes care of that, and also takes care of copying data
end function snow_tile_copy_ctor

! ============================================================================
subroutine delete_snow_tile(snow)
  type(snow_tile_type), pointer :: snow

  ! no need to deallocate components of tile, because F2003 takes care of
  ! allocatable components deallocation when tile is deallocated
  deallocate(snow)
end subroutine delete_snow_tile

! =============================================================================
function snow_tiles_can_be_merged(snow1,snow2) result(response)
  logical :: response
  type(snow_tile_type), intent(in) :: snow1,snow2

  response = .TRUE.
end function snow_tiles_can_be_merged

! =============================================================================
subroutine merge_snow_tiles(snow1, w1, snow2, w2)
  type(snow_tile_type), intent(in)    :: snow1
  type(snow_tile_type), intent(inout) :: snow2
  real                , intent(in)    :: w1, w2 ! relative weights

  ! ---- local vars
  real    :: x1, x2 ! normalized weights
  real    :: HEAT1, HEAT2
  integer :: i

  ! calculate normalized weights
  x1 = w1/(w1+w2)
  x2 = 1-x1

  do i = 1, num_l
    HEAT1 = (mc_fict*dz(i)+clw*snow1%wl(i)+csw*snow1%ws(i))*(snow1%T(i)-tfreeze)
    HEAT2 = (mc_fict*dz(i)+clw*snow2%wl(i)+csw*snow2%ws(i))*(snow2%T(i)-tfreeze)
    snow2%wl(i) = snow1%wl(i)*x1 + snow2%wl(i)*x2
    snow2%ws(i) = snow1%ws(i)*x1 + snow2%ws(i)*x2
    if (snow2%wl(i)/=0.or.snow2%ws(i)/=0) then
       snow2%T(i)  = (HEAT1*x1+HEAT2*x2)/&
            (mc_fict*dz(i)+clw*snow2%wl(i)+csw*snow2%ws(i))+tfreeze
    else
       snow2%T(i)  = snow1%T(i)*x1 + snow2%T(i)*x2
    endif
  enddo
end subroutine merge_snow_tiles

! =============================================================================
! returns true if tile fits the specified selector
function snow_is_selected(snow, sel)
  logical snow_is_selected
  type(tile_selector_type),  intent(in) :: sel
  type(snow_tile_type),      intent(in) :: snow

  snow_is_selected = .TRUE.
end function snow_is_selected

! ============================================================================
! retruns tag of the tile
function get_snow_tile_tag(snow) result(tag)
  integer :: tag
  type(snow_tile_type), intent(in) :: snow

  tag = snow%tag
end function get_snow_tile_tag

! ============================================================================
! compute snow thermodynmamic properties.
subroutine snow_data_thermodynamics ( snow_rh, thermal_cond)
  real, intent(out) :: snow_rh
  real, intent(out) :: thermal_cond(:)

  ! snow surface assumed to have air at saturation
  snow_rh = 1

  ! these will eventually be functions of water contents and T.
  thermal_cond  = thermal_cond_ref

end subroutine snow_data_thermodynamics


! ============================================================================
! compute snow hydraulic properties (assumed dependent only on wl)
subroutine snow_data_hydraulics (wl, ws, psi, hyd_cond )
  real, intent(in),  dimension(:) :: wl, ws
  real, intent(out), dimension(:) :: psi, hyd_cond

  ! ---- local vars
  integer :: l

  do l = 1, num_l
    psi     (l) = psi_sat *(w_sat/(wl(l)+ws(l)))**chb
    hyd_cond(l) = k_sat*(wl(l)/w_sat)**(3+2*chb)
  enddo

end subroutine snow_data_hydraulics


! ============================================================================
! compute snow area
subroutine snow_data_area ( snow_depth, snow_area )
    real, intent(in)  :: snow_depth
    real, intent(out) :: snow_area

  snow_area = 0.
  if (use_mcm_masking) then
     snow_area = min(1., 0.5*sqrt(max(0.,snow_depth)/depth_crit))
  else
     snow_area = max(0.,snow_depth) / (max(0.,snow_depth) + depth_crit)
  endif

end subroutine snow_data_area

! ============================================================================
! compute snow properties needed to do soil-canopy-atmos energy balance
subroutine snow_radiation ( snow_T, cosz, on_glacier, l, &
     snow_refl_dir, snow_refl_dif, snow_refl_lw, snow_emis )
  real, intent(in) :: snow_T  ! snow temperature, deg K
  real, intent(in) :: cosz ! cosine of zenith angle
  integer, intent(in) :: l ! grid cell index in unstructured grid
  logical, intent(in) :: on_glacier ! TRUE if snow is on glacier
  real, intent(out) :: snow_refl_dir(NBANDS), snow_refl_dif(NBANDS), snow_refl_lw, snow_emis

  logical :: in_box ! true if the current point is within one of the boxes
  integer :: i ! box index

  in_box = .FALSE.
  if (distinct_snow_on_glacier.and.on_glacier) then
     do i = 1,n_boxes
         in_box = in_box.or.within_box(lnd%ug_lon(l),lnd%ug_lat(l), box_W(i),box_E(i),box_S(i),box_N(i))
     enddo
  endif
  if (on_glacier.and.in_box.and.distinct_snow_on_glacier) then
     call snow_rad_calculations ( snow_T, cosz, &
        f_iso_warm_on_glacier, f_vol_warm_on_glacier, f_geo_warm_on_glacier, &
        f_iso_cold_on_glacier, f_vol_cold_on_glacier, f_geo_cold_on_glacier, &
        refl_snow_min_dir_on_glacier, refl_snow_max_dir_on_glacier, &
        refl_snow_min_dif_on_glacier, refl_snow_max_dif_on_glacier, &
        snow_refl_dir, snow_refl_dif, snow_refl_lw, snow_emis )
  else
     call snow_rad_calculations ( snow_T, cosz, &
        f_iso_warm, f_vol_warm, f_geo_warm, &
        f_iso_cold, f_vol_cold, f_geo_cold, &
        refl_snow_min_dir, refl_snow_max_dir, &
        refl_snow_min_dif, refl_snow_max_dif, &
        snow_refl_dir, snow_refl_dif, snow_refl_lw, snow_emis )
  endif
end subroutine snow_radiation

! ============================================================================
! given coordinates of the point and box boundaries, returns TRUE if the point
! is within the specified box
logical function within_box(lon,lat,W,E,S,N)
   real, intent(in) :: lon,lat  ! coordinares of the point
   real, intent(in) :: W,E,S,N  ! bundaries of the box

   real :: lon1 ! longitude converted to the same range as the box boundaries
   within_box = (S<=lat).and.(lat<=N)
   if (.not.within_box) return ! no need to check anything else
   ! convert longitude to the same range as the western boundary of the box
   lon1=lon-2*PI*floor((lon-W)/(2*PI))
   within_box = (W<=lon1).and.(lon1<=E)
end function within_box

! ============================================================================
subroutine snow_rad_calculations ( snow_T, cosz, &
     f_iso_warm, f_vol_warm, f_geo_warm, &
     f_iso_cold, f_vol_cold, f_geo_cold, &
     refl_snow_min_dir, refl_snow_max_dir, &
     refl_snow_min_dif, refl_snow_max_dif, &
     snow_refl_dir, snow_refl_dif, snow_refl_lw, snow_emis )
  real, intent(in) :: snow_T  ! snow temperature, deg K
  real, intent(in) :: cosz ! cosine of zenith angle
  real, intent(in), dimension(NBANDS) :: &
     f_iso_warm, f_vol_warm, f_geo_warm, &
     f_iso_cold, f_vol_cold, f_geo_cold, &
     refl_snow_min_dir, refl_snow_max_dir, refl_snow_min_dif, refl_snow_max_dif
  real, intent(out) :: snow_refl_dir(NBANDS), snow_refl_dif(NBANDS), snow_refl_lw, snow_emis

  ! ---- local vars
  real :: blend
  real :: warm_value_dir(NBANDS), cold_value_dir(NBANDS)
  real :: warm_value_dif(NBANDS), cold_value_dif(NBANDS)
  real :: zenith_angle, zsq, zcu

  blend = max(0.,min(1.,1.-(tfreeze-snow_T)/t_range))
  if (use_brdf) then
     zenith_angle = acos(cosz)
     zsq = zenith_angle*zenith_angle
     zcu = zenith_angle*zsq
     warm_value_dir = f_iso_warm*(g0_iso+g1_iso*zsq+g2_iso*zcu) &
                    + f_vol_warm*(g0_vol+g1_vol*zsq+g2_vol*zcu) &
                    + f_geo_warm*(g0_geo+g1_geo*zsq+g2_geo*zcu)
     cold_value_dir = f_iso_cold*(g0_iso+g1_iso*zsq+g2_iso*zcu) &
                    + f_vol_cold*(g0_vol+g1_vol*zsq+g2_vol*zcu) &
                    + f_geo_cold*(g0_geo+g1_geo*zsq+g2_geo*zcu)
     cold_value_dif = g_iso*f_iso_cold + g_vol*f_vol_cold + g_geo*f_geo_cold
     warm_value_dif = g_iso*f_iso_warm + g_vol*f_vol_warm + g_geo*f_geo_warm
  else
     warm_value_dir = refl_snow_min_dir
     cold_value_dir = refl_snow_max_dir
     warm_value_dif = refl_snow_min_dif
     cold_value_dif = refl_snow_max_dif
  endif
  snow_refl_dir = cold_value_dir + blend*(warm_value_dir-cold_value_dir)
  snow_refl_dif = cold_value_dif + blend*(warm_value_dif-cold_value_dif)
  snow_emis     = emis_snow_max + blend*(emis_snow_min-emis_snow_max  )
  snow_refl_lw  = 1 - snow_emis
end subroutine snow_rad_calculations

! ============================================================================
subroutine snow_roughness(snow, snow_z0s, snow_z0m)
  type(snow_tile_type), intent(in) :: snow ! not used
  real, intent(out):: snow_z0s, snow_z0m

  snow_z0m =  z0_momentum
  snow_z0s =  z0_momentum * exp(-k_over_B)
end subroutine snow_roughness

! ============================================================================
subroutine snow_tile_stock_pe (snow, twd_liq, twd_sol  )
  type(snow_tile_type),  intent(in)    :: snow
  real,                  intent(out)   :: twd_liq, twd_sol
  integer n

  twd_liq = 0.
  twd_sol = 0.
  do n=1, size(snow%wl)
    twd_liq = twd_liq + snow%wl(n)
    twd_sol = twd_sol + snow%ws(n)
    enddo

end subroutine snow_tile_stock_pe

! ============================================================================
! returns snow heat content, J/m2
function snow_tile_heat (snow) result(heat) ; real heat
  type(snow_tile_type), intent(in)  :: snow

  integer :: i

  heat = 0
  do i = 1,num_l
     heat = heat - snow%ws(i)*hlf &
        + (mc_fict*dz(i) + clw*snow%wl(i) + csw*snow%ws(i))  &
                                      * (snow%T(i)-tfreeze)
  enddo
end function snow_tile_heat

! ============================================================================
! returns true if snow plays a role
function snow_active(snow) ; logical snow_active
  type(snow_tile_type), intent(in)  :: snow
  snow_active = ( sum(snow%ws(1:num_l)) > 0 )
end function snow_active

end module snow_tile_mod
