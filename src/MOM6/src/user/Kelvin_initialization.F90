module Kelvin_initialization

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_dyn_horgrid,    only : dyn_horgrid_type
use MOM_error_handler,  only : MOM_mesg, MOM_error, FATAL, WARNING, is_root_pe
use MOM_file_parser,    only : get_param, log_version, param_file_type
use MOM_grid,           only : ocean_grid_type
use MOM_open_boundary,  only : ocean_OBC_type, OBC_NONE
use MOM_open_boundary,  only : OBC_segment_type, register_OBC
use MOM_open_boundary,  only : OBC_DIRECTION_N, OBC_DIRECTION_E
use MOM_open_boundary,  only : OBC_DIRECTION_S, OBC_DIRECTION_W
use MOM_open_boundary,  only : OBC_registry_type
use MOM_verticalGrid,   only : verticalGrid_type
use MOM_time_manager,   only : time_type, set_time, time_type_to_real

implicit none ; private

#include <MOM_memory.h>

public Kelvin_set_OBC_data, Kelvin_initialize_topography
public register_Kelvin_OBC, Kelvin_OBC_end

!> Control structure for Kelvin wave open boundaries.
type, public :: Kelvin_OBC_CS ; private
  integer :: mode = 0          !< Vertical mode
  real    :: coast_angle = 0   !< Angle of coastline
  real    :: coast_offset1 = 0 !< Longshore distance to coastal angle
  real    :: coast_offset2 = 0 !< Longshore distance to coastal angle
  real    :: N0 = 0            !< Brunt-Vaisala frequency
  real    :: H0 = 0            !< Bottom depth
  real    :: F_0               !< Coriolis parameter
  real    :: plx = 0           !< Longshore wave parameter
  real    :: pmz = 0           !< Vertical wave parameter
  real    :: lambda = 0        !< Vertical wave parameter
  real    :: omega             !< Frequency
  real    :: rho_range         !< Density range
  real    :: rho_0             !< Mean density
end type Kelvin_OBC_CS

! This include declares and sets the variable "version".
#include "version_variable.h"

contains

!> Add Kelvin wave to OBC registry.
function register_Kelvin_OBC(param_file, CS, OBC_Reg)
  type(param_file_type),    intent(in) :: param_file !< parameter file.
  type(Kelvin_OBC_CS),      pointer    :: CS         !< Kelvin wave control structure.
  type(OBC_registry_type),  pointer    :: OBC_Reg    !< OBC registry.
  logical                              :: register_Kelvin_OBC
  character(len=40)  :: mdl = "register_Kelvin_OBC"  !< This subroutine's name.
  character(len=32)  :: casename = "Kelvin wave"     !< This case's name.
  character(len=200) :: config

  if (associated(CS)) then
    call MOM_error(WARNING, "register_Kelvin_OBC called with an "// &
                            "associated control structure.")
    return
  endif
  allocate(CS)

  call log_version(param_file, mdl, version, "")
  call get_param(param_file, mdl, "KELVIN_WAVE_MODE", CS%mode, &
                 "Vertical Kelvin wave mode imposed at upstream open boundary.", &
                 default=0)
  call get_param(param_file, mdl, "F_0", CS%F_0, &
                 default=0.0, do_not_log=.true.)
  call get_param(param_file, mdl, "TOPO_CONFIG", config, do_not_log=.true.)
  if (trim(config) == "Kelvin") then
    call get_param(param_file, mdl, "ROTATED_COAST_OFFSET_1", CS%coast_offset1, &
                   "The distance along the southern and northern boundaries \n"//&
                   "at which the coasts angle in.", &
                   units="km", default=100.0)
    call get_param(param_file, mdl, "ROTATED_COAST_OFFSET_2", CS%coast_offset2, &
                   "The distance from the southern and northern boundaries \n"//&
                   "at which the coasts angle in.", &
                   units="km", default=10.0)
    call get_param(param_file, mdl, "ROTATED_COAST_ANGLE", CS%coast_angle, &
                   "The angle of the southern bondary beyond X=ROTATED_COAST_OFFSET.", &
                   units="degrees", default=11.3)
    CS%coast_angle = CS%coast_angle * (atan(1.0)/45.) ! Convert to radians
    CS%coast_offset1 = CS%coast_offset1 * 1.e3          ! Convert to m
    CS%coast_offset2 = CS%coast_offset2 * 1.e3          ! Convert to m
  endif
  if (CS%mode /= 0) then
    call get_param(param_file, mdl, "DENSITY_RANGE", CS%rho_range, &
                   default=2.0, do_not_log=.true.)
    call get_param(param_file, mdl, "RHO_0", CS%rho_0, &
                   default=1035.0, do_not_log=.true.)
    call get_param(param_file, mdl, "MAXIMUM_DEPTH", CS%H0, &
                   default=1000.0, do_not_log=.true.)
  endif

  ! Register the Kelvin open boundary.
  call register_OBC(casename, param_file, OBC_Reg)
  register_Kelvin_OBC = .true.

end function register_Kelvin_OBC

!> Clean up the Kelvin wave OBC from registry.
subroutine Kelvin_OBC_end(CS)
  type(Kelvin_OBC_CS), pointer    :: CS         !< Kelvin wave control structure.

  if (associated(CS)) then
    deallocate(CS)
  endif
end subroutine Kelvin_OBC_end

! -----------------------------------------------------------------------------
!> This subroutine sets up the Kelvin topography and land mask
subroutine Kelvin_initialize_topography(D, G, param_file, max_depth)
  type(dyn_horgrid_type),           intent(in)  :: G !< The dynamic horizontal grid type
  real, dimension(SZI_(G),SZJ_(G)), intent(out) :: D !< Ocean bottom depth in m
  type(param_file_type),            intent(in)  :: param_file !< Parameter file structure
  real,                             intent(in)  :: max_depth  !< Maximum depth of model in m
  ! Local variables
  character(len=40)  :: mdl = "Kelvin_initialize_topography" ! This subroutine's name.
  real :: min_depth ! The minimum and maximum depths in m.
  real :: PI ! 3.1415...
  real :: coast_offset1, coast_offset2, coast_angle, right_angle
  integer :: i, j

  call MOM_mesg("  Kelvin_initialization.F90, Kelvin_initialize_topography: setting topography", 5)

  call get_param(param_file, mdl, "MINIMUM_DEPTH", min_depth, &
                 "The minimum depth of the ocean.", units="m", default=0.0)
  call get_param(param_file, mdl, "ROTATED_COAST_OFFSET_1", coast_offset1, &
                 default=100.0, do_not_log=.true.)
  call get_param(param_file, mdl, "ROTATED_COAST_OFFSET_2", coast_offset2, &
                 default=10.0, do_not_log=.true.)
  call get_param(param_file, mdl, "ROTATED_COAST_ANGLE", coast_angle, &
                 default=11.3, do_not_log=.true.)

  coast_angle = coast_angle * (atan(1.0)/45.) ! Convert to radians
  right_angle = 2 * atan(1.0)

  do j=G%jsc,G%jec ; do i=G%isc,G%iec
    D(i,j)=max_depth
    ! Southern side
    if ((G%geoLonT(i,j) - G%west_lon > coast_offset1) .AND. &
        (atan2(G%geoLatT(i,j) - G%south_lat + coast_offset2, &
         G%geoLonT(i,j) - G%west_lon - coast_offset1) < coast_angle)) &
             D(i,j)=0.5*min_depth
    ! Northern side
    if ((G%geoLonT(i,j) - G%west_lon < G%len_lon - coast_offset1) .AND. &
        (atan2(G%len_lat + G%south_lat + coast_offset2 - G%geoLatT(i,j), &
         G%len_lon + G%west_lon - coast_offset1 - G%geoLonT(i,j)) < coast_angle)) &
             D(i,j)=0.5*min_depth

    if (D(i,j) > max_depth) D(i,j) = max_depth
    if (D(i,j) < min_depth) D(i,j) = 0.5*min_depth
  enddo ; enddo

end subroutine Kelvin_initialize_topography

!> This subroutine sets the properties of flow at open boundary conditions.
subroutine Kelvin_set_OBC_data(OBC, CS, G, h, Time)
  type(ocean_OBC_type),   pointer    :: OBC  !< This open boundary condition type specifies
                                             !! whether, where, and what open boundary
                                             !! conditions are used.
  type(Kelvin_OBC_CS),    pointer    :: CS   !< Kelvin wave control structure.
  type(ocean_grid_type),  intent(in) :: G    !< The ocean's grid structure.
  real, dimension(SZI_(G),SZJ_(G),SZK_(G)),  intent(in) :: h !< layer thickness.
  type(time_type),        intent(in) :: Time !< model time.

  ! The following variables are used to set up the transport in the Kelvin example.
  real :: time_sec, cff
  real :: PI
  integer :: i, j, k, n, is, ie, js, je, isd, ied, jsd, jed, nz
  integer :: IsdB, IedB, JsdB, JedB
  real    :: fac, x, y, x1, y1
  real    :: val1, val2, sina, cosa
  type(OBC_segment_type), pointer :: segment

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  IsdB = G%IsdB ; IedB = G%IedB ; JsdB = G%JsdB ; JedB = G%JedB

  if (.not.associated(OBC)) call MOM_error(FATAL, 'Kelvin_initialization.F90: '// &
        'Kelvin_set_OBC_data() was called but OBC type was not initialized!')

  time_sec = time_type_to_real(Time)
  PI = 4.0*atan(1.0)
  fac = 1.0

  if (CS%mode == 0) then
    CS%omega = 2.0 * PI / (12.42 * 3600.0)      ! M2 Tide period
    val1 = sin(CS%omega * time_sec)
  else
    CS%N0 = sqrt(CS%rho_range / CS%rho_0 * G%g_Earth * CS%H0)
    ! Two wavelengths in domain
    CS%plx = 4.0 * PI / G%len_lon
    CS%pmz = PI * CS%mode / CS%H0
    CS%lambda = CS%pmz * CS%F_0 / CS%N0
    CS%omega = CS%F_0 * CS%plx / CS%lambda
  endif

  sina = sin(CS%coast_angle)
  cosa = cos(CS%coast_angle)
  do n=1,OBC%number_of_segments
    segment => OBC%segment(n)
    if (.not. segment%on_pe) cycle
    ! Apply values to the inflow end only.
    if (segment%direction == OBC_DIRECTION_E) cycle
    if (segment%direction == OBC_DIRECTION_N) cycle

    ! This should be somewhere else...
    segment%Velocity_nudging_timescale_in = 1.0/(0.3*86400)

    if (segment%direction == OBC_DIRECTION_W) then
      IsdB = segment%HI%IsdB ; IedB = segment%HI%IedB
      jsd = segment%HI%jsd ; jed = segment%HI%jed
      do j=jsd,jed ; do I=IsdB,IedB
        x1 = 1000. * G%geoLonCu(I,j)
        y1 = 1000. * G%geoLatCu(I,j)
        x = (x1 - CS%coast_offset1) * cosa + y1 * sina
        y = - (x1 - CS%coast_offset1) * sina + y1 * cosa
        if (CS%mode == 0) then
          cff = sqrt(G%g_Earth * 0.5 * (G%bathyT(i+1,j) + G%bathyT(i,j)))
          val2 = fac * exp(- CS%F_0 * y / cff)
          segment%eta(I,j) = val2 * cos(CS%omega * time_sec)
          segment%normal_vel_bt(I,j) = val1 * cff * cosa /         &
                 (0.5 * (G%bathyT(i+1,j) + G%bathyT(i,j))) * val2
        else
          segment%eta(I,j) = 0.0
          segment%normal_vel_bt(I,j) = 0.0
          if (segment%nudged) then
            do k=1,nz
              segment%nudged_normal_vel(I,j,k) = fac * CS%lambda / CS%F_0 * &
                   exp(- CS%lambda * y) * cos(PI * CS%mode * (k - 0.5) / nz) * &
                   cos(CS%omega * time_sec)
            enddo
          elseif (segment%specified) then
            do k=1,nz
              segment%normal_vel(I,j,k) = fac * CS%lambda / CS%F_0 * &
                   exp(- CS%lambda * y) * cos(PI * CS%mode * (k - 0.5) / nz) * &
                   cos(CS%omega * time_sec)
              segment%normal_trans(I,j,k) = segment%normal_vel(I,j,k) * &
                   h(i+1,j,k) * G%dyCu(I,j)
            enddo
          endif
        endif
      enddo ; enddo
    else
      isd = segment%HI%isd ; ied = segment%HI%ied
      JsdB = segment%HI%JsdB ; JedB = segment%HI%JedB
      do J=JsdB,JedB ; do i=isd,ied
        x1 = 1000. * G%geoLonCv(i,J)
        y1 = 1000. * G%geoLatCv(i,J)
        x = (x1 - CS%coast_offset1) * cosa + y1 * sina
        y = - (x1 - CS%coast_offset1) * sina + y1 * cosa
        if (CS%mode == 0) then
          cff = sqrt(G%g_Earth * 0.5 * (G%bathyT(i,j+1) + G%bathyT(i,j)))
          val2 = fac * exp(- 0.5 * (G%CoriolisBu(I,J) + G%CoriolisBu(I-1,J)) * y / cff)
          segment%eta(I,j) = val2 * cos(CS%omega * time_sec)
          segment%normal_vel_bt(I,j) = val1 * cff * sina /       &
                 (0.5 * (G%bathyT(i+1,j) + G%bathyT(i,j))) * val2
        else
          segment%eta(i,J) = 0.0
          segment%normal_vel_bt(i,J) = 0.0
          if (segment%nudged) then
            do k=1,nz
              segment%nudged_normal_vel(i,J,k) = fac * CS%lambda / CS%F_0 * &
                   exp(- CS%lambda * y) * cos(PI * CS%mode * (k - 0.5) / nz) * cosa
            enddo
          elseif (segment%specified) then
            do k=1,nz
              segment%normal_vel(i,J,k) = fac * CS%lambda / CS%F_0 * &
                   exp(- CS%lambda * y) * cos(PI * CS%mode * (k - 0.5) / nz) * cosa
              segment%normal_trans(i,J,k) = segment%normal_vel(i,J,k) * &
                   h(i,j+1,k) * G%dxCv(i,J)
            enddo
          endif
        endif
      enddo ; enddo
    endif
  enddo

end subroutine Kelvin_set_OBC_data

!> \class Kelvin_Initialization
!!
!! The module configures the model for the Kelvin wave experiment.
!! Kelvin = coastally-trapped Kelvin waves from the ROMS examples.
!! Initialize with level surfaces and drive the wave in at the west,
!! radiate out at the east.
end module Kelvin_initialization
