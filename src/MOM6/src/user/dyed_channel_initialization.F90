module dyed_channel_initialization

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_dyn_horgrid,     only : dyn_horgrid_type
use MOM_error_handler,   only : MOM_mesg, MOM_error, FATAL, WARNING, is_root_pe
use MOM_file_parser,     only : get_param, log_version, param_file_type
use MOM_get_input,       only : directories
use MOM_grid,            only : ocean_grid_type
use MOM_open_boundary,   only : ocean_OBC_type, OBC_NONE, OBC_SIMPLE
use MOM_open_boundary,   only : OBC_segment_type, register_segment_tracer
use MOM_open_boundary,   only : OBC_registry_type, register_OBC
use MOM_time_manager,    only : time_type, set_time, time_type_to_real
use MOM_tracer_registry, only : tracer_registry_type, tracer_name_lookup
use MOM_tracer_registry, only : tracer_type
use MOM_variables,       only : thermo_var_ptrs
use MOM_verticalGrid,    only : verticalGrid_type

implicit none ; private

#include <MOM_memory.h>

public dyed_channel_set_OBC_tracer_data, dyed_channel_OBC_end
public register_dyed_channel_OBC, dyed_channel_update_flow

!> Control structure for tidal bay open boundaries.
type, public :: dyed_channel_OBC_CS ; private
  real :: zonal_flow = 8.57         !< Mean inflow
  real :: tidal_amp = 0.0           !< Sloshing amplitude
  real :: frequency  = 0.0          !< Sloshing frequency
end type dyed_channel_OBC_CS

integer :: ntr = 0

contains

!> Add dyed channel to OBC registry.
function register_dyed_channel_OBC(param_file, CS, OBC_Reg)
  type(param_file_type),     intent(in) :: param_file !< parameter file.
  type(dyed_channel_OBC_CS), pointer    :: CS         !< tidal bay control structure.
  type(OBC_registry_type),   pointer    :: OBC_Reg    !< OBC registry.
  logical                               :: register_dyed_channel_OBC
  character(len=32)  :: casename = "dyed channel"     !< This case's name.
  character(len=40)  :: mdl = "register_dyed_channel_OBC" ! This subroutine's name.

  if (associated(CS)) then
    call MOM_error(WARNING, "register_dyed_channel_OBC called with an "// &
                            "associated control structure.")
    return
  endif
  allocate(CS)

  call get_param(param_file, mdl, "CHANNEL_MEAN_FLOW", CS%zonal_flow, &
                 "Mean zonal flow imposed at upstream open boundary.", &
                 units="m/s", default=8.57)
  call get_param(param_file, mdl, "CHANNEL_TIDAL_AMP", CS%tidal_amp, &
                 "Sloshing amplitude imposed at upstream open boundary.", &
                 units="m/s", default=0.0)
  call get_param(param_file, mdl, "CHANNEL_FLOW_FREQUENCY", CS%frequency, &
                 "Frequency of oscillating zonal flow.", &
                 units="s-1", default=0.0)

  ! Register the open boundaries.
  call register_OBC(casename, param_file, OBC_Reg)
  register_dyed_channel_OBC = .true.

end function register_dyed_channel_OBC

!> Clean up the dyed_channel OBC from registry.
subroutine dyed_channel_OBC_end(CS)
  type(dyed_channel_OBC_CS), pointer :: CS    !< tidal bay control structure.

  if (associated(CS)) then
    deallocate(CS)
  endif
end subroutine dyed_channel_OBC_end

!> This subroutine sets the dye and flow properties at open boundary conditions.
subroutine dyed_channel_set_OBC_tracer_data(OBC, G, GV, param_file, tr_Reg)
  type(ocean_OBC_type),       pointer    :: OBC !< This open boundary condition type specifies
                                                !! whether, where, and what open boundary
                                                !! conditions are used.
  type(ocean_grid_type),      intent(in) :: G   !< The ocean's grid structure.
  type(verticalGrid_type),    intent(in) :: GV  !< The ocean's vertical grid structure.
  type(param_file_type),      intent(in) :: param_file !< A structure indicating the open file
                                                !! to parse for model parameter values.
  type(tracer_registry_type), pointer    :: tr_Reg !< Tracer registry.

! Local variables
  character(len=40)  :: mdl = "dyed_channel_set_OBC_tracer_data" ! This subroutine's name.
  character(len=80)  :: name, longname
  integer :: i, j, k, l, itt, isd, ied, jsd, jed, m, n
  integer :: IsdB, IedB, JsdB, JedB
  real :: dye
  type(OBC_segment_type), pointer :: segment
  type(tracer_type), pointer      :: tr_ptr

  if (.not.associated(OBC)) call MOM_error(FATAL, 'dyed_channel_initialization.F90: '// &
        'dyed_channel_set_OBC_data() was called but OBC type was not initialized!')

  call get_param(param_file, mdl, "NUM_DYE_TRACERS", ntr, &
                 "The number of dye tracers in this run. Each tracer \n"//&
                 "should have a separate boundary segment.", default=0,   &
                 do_not_log=.true.)

  if (OBC%number_of_segments .lt. ntr) then
    call MOM_error(WARNING, "Error in dyed_obc segment setup")
    return   !!! Need a better error message here
  endif

! ! Set the inflow values of the dyes, one per segment.
! ! We know the order: north, south, east, west
  do m=1,ntr
    write(name,'("dye_",I2.2)') m
    write(longname,'("Concentration of dyed_obc Tracer ",I2.2, " on segment ",I2.2)') m, m
    call tracer_name_lookup(tr_Reg, tr_ptr, name)

    do n=1,OBC%number_of_segments
      if (n == m) then
        dye = 1.0
      else
        dye = 0.0
      endif
      call register_segment_tracer(tr_ptr, param_file, GV, &
                                   OBC%segment(n), OBC_scalar=dye)
    enddo
  enddo

end subroutine dyed_channel_set_OBC_tracer_data

!> This subroutine updates the long-channel flow
subroutine dyed_channel_update_flow(OBC, CS, G, Time)
  type(ocean_OBC_type),       pointer    :: OBC !< This open boundary condition type specifies
                                                !! whether, where, and what open boundary
                                                !! conditions are used.
  type(dyed_channel_OBC_CS),  pointer    :: CS  !< tidal bay control structure.
  type(ocean_grid_type),      intent(in) :: G   !< The ocean's grid structure.
  type(time_type),            intent(in) :: Time !< model time.

! Local variables
  character(len=40)  :: mdl = "dyed_channel_update_flow" ! This subroutine's name.
  character(len=80)  :: name
  real :: flow, time_sec, PI
  integer :: i, j, k, l, itt, isd, ied, jsd, jed, m, n
  integer :: IsdB, IedB, JsdB, JedB
  type(OBC_segment_type), pointer :: segment

  if (.not.associated(OBC)) call MOM_error(FATAL, 'dyed_channel_initialization.F90: '// &
        'dyed_channel_update_flow() was called but OBC type was not initialized!')

  time_sec = time_type_to_real(Time)
  PI = 4.0*atan(1.0)

  do l=1, OBC%number_of_segments
    segment => OBC%segment(l)
    if (.not. segment%on_pe) cycle
    if (segment%gradient) cycle
    if (segment%oblique .and. .not. segment%nudged .and. .not. segment%Flather) cycle

    if (segment%is_E_or_W) then
      jsd = segment%HI%jsd ; jed = segment%HI%jed
      IsdB = segment%HI%IsdB ; IedB = segment%HI%IedB
      if (CS%frequency == 0.0) then
        flow = CS%zonal_flow
      else
        flow = CS%zonal_flow + CS%tidal_amp * cos(2 * PI * CS%frequency * time_sec)
      endif
      do k=1,G%ke
        do j=jsd,jed ; do I=IsdB,IedB
          if (segment%specified .or. segment%nudged) then
            segment%normal_vel(I,j,k) = flow
          endif
          if (segment%specified) then
            segment%normal_trans(I,j,k) = flow * G%dyCu(I,j)
          endif
        enddo ; enddo
      enddo
      do j=jsd,jed ; do I=IsdB,IedB
        segment%normal_vel_bt(I,j) = flow
      enddo ; enddo
    else
      isd = segment%HI%isd ; ied = segment%HI%ied
      JsdB = segment%HI%JsdB ; JedB = segment%HI%JedB
      do J=JsdB,JedB ; do i=isd,ied
        segment%normal_vel_bt(i,J) = 0.0
      enddo ; enddo
    endif
  enddo

end subroutine dyed_channel_update_flow

!> \namespace dyed_channel_initialization
!! Setting dyes, one for painting the inflow on each side.
end module dyed_channel_initialization
