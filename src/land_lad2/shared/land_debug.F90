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
module land_debug_mod

use mpp_mod, only: mpp_max, input_nml_file
use constants_mod, only: PI
use fms_mod, only: error_mesg, check_nml_error, stdlog, &
      mpp_pe, mpp_npes, mpp_root_pe, string, FATAL, WARNING, NOTE
use time_manager_mod, only : &
     time_type, get_date, set_date, operator(<=), operator(>=)
use grid_mod, only: get_grid_ntiles
use land_data_mod, only: lnd, log_version

! NOTE TO SELF: the "!$" sentinels are not comments: they are compiled if OpenMP
! support is turned on
!$ use omp_lib, only: OMP_GET_MAX_THREADS, OMP_GET_THREAD_NUM

implicit none
private

! ==== public interfaces =====================================================
public :: land_debug_init
public :: land_debug_end

public :: set_current_point
public :: get_current_point
public :: current_i, current_j, current_k, current_face
public :: is_watch_point
public :: is_watch_cell
public :: is_watch_time
public :: get_watch_point

public :: check_temp_range
public :: check_var_range
public :: check_conservation

public :: land_error_message
public :: log_date
public :: dpri

interface dpri
   module procedure debug_printout_r0d
   module procedure debug_printout_i0d
   module procedure debug_printout_l0d
   module procedure debug_printout_r1d
   module procedure debug_printout_i1d
   module procedure debug_printout_r2d
end interface dpri

interface check_var_range
   module procedure check_var_range_0d
   module procedure check_var_range_1d
end interface check_var_range

interface check_temp_range
   module procedure check_temp_range_0d
   module procedure check_temp_range_1d
end interface check_temp_range

interface set_current_point
   module procedure set_current_point_sg
   module procedure set_current_point_ug
end interface set_current_point

! conservation tolerances for use across the code. This module doesn't use
! them, just serves as a convenient place to share them across all land code
public :: water_cons_tol
public :: carbon_cons_tol
public :: heat_cons_tol
public :: do_check_conservation

! ==== module constants ======================================================
character(len=*), parameter :: module_name = 'land_debug_mod'
#include "../shared/version_variable.inc"

! ==== module variables ======================================================
integer, allocatable :: current_debug_level(:)
integer              :: mosaic_tile_sg = 0, mosaic_tile_ug = 0
integer, allocatable :: curr_i(:), curr_j(:), curr_k(:), curr_l(:)
type(time_type)      :: start_watch_time, stop_watch_time
character(128)       :: fixed_format

!---- namelist ---------------------------------------------------------------
integer :: watch_point(4)=(/0,0,0,1/) ! coordinates of the point of interest,
           ! i,j,tile,mosaic_tile
integer :: watch_point_lindex = 0  ! watch point index in unstructure grid.
integer :: start_watching(6) = (/    1, 1, 1, 0, 0, 0 /)
integer :: stop_watching(6)  = (/ 9999, 1, 1, 0, 0, 0 /)
logical :: watch_conservation = .FALSE. ! if true, conservation check reports are
           ! printed for watch_point, in addition to regular debug output
real    :: temp_lo = 120.0 ! lower limit of "reasonable" temperature range, deg K
real    :: temp_hi = 373.0 ! upper limit of "reasonable" temperature range, deg K
logical :: print_hex_debug = .FALSE. ! if TRUE, hex representation of debug
           ! values is also printed
integer :: label_len = 12  ! minimum length of text labels for debug output
logical :: trim_labels = .FALSE. ! if TRUE, the length of text labels in debug
           ! printout is never allowed to exceed label_len, resulting in
           ! trimming of the labels. Set it to TRUE to match earlier debug
           ! printout
namelist/land_debug_nml/ watch_point, &
   start_watching, stop_watching, watch_conservation, &
   temp_lo, temp_hi, &
   print_hex_debug, label_len, trim_labels

logical, protected :: do_check_conservation = .FALSE.
real, protected    :: water_cons_tol  = 1e-11 ! tolerance of water conservation checks
real, protected    :: carbon_cons_tol = 1e-13 ! tolerance of carbon conservation checks
real, protected    :: heat_cons_tol   = 1e-8  ! tolerance of heat conservation checks
namelist/land_conservation_nml/ do_check_conservation, &
      water_cons_tol, carbon_cons_tol, heat_cons_tol

contains

! ============================================================================
subroutine land_debug_init()
  ! ---- local vars
  integer :: unit, ierr, io, ntiles, l
  integer :: max_threads

  call log_version(version, module_name, &
  __FILE__)

  read (input_nml_file, nml=land_debug_nml, iostat=io)
  ierr = check_nml_error(io, 'land_debug_nml')
  read (input_nml_file, nml=land_conservation_nml, iostat=io)
  ierr = check_nml_error(io, 'land_conservation_nml')
  if (mpp_pe() == mpp_root_pe()) then
     unit=stdlog()
     write(unit, nml=land_debug_nml)
     write(unit, nml=land_conservation_nml)
  endif

  ! set number of our mosaic tile
  call get_grid_ntiles('LND',ntiles)
  mosaic_tile_sg = ntiles*mpp_pe()/mpp_npes() + 1  ! assumption

  ! set number of threads and allocate by-thread arrays
    max_threads = 1
!$  max_threads = OMP_GET_MAX_THREADS()
  allocate(curr_i(max_threads),curr_j(max_threads),curr_k(max_threads),curr_l(max_threads))
  allocate(current_debug_level(max_threads))
  current_debug_level(:) = 0

  ! construct the format string for output
  fixed_format = '(a'//trim(string(label_len))//',99g23.16)'

  start_watch_time = set_date(start_watching(1), start_watching(2), start_watching(3), &
                              start_watching(4), start_watching(5), start_watching(6)  )
  stop_watch_time  = set_date( stop_watching(1),  stop_watching(2),  stop_watching(3), &
                               stop_watching(4),  stop_watching(5),  stop_watching(6)  )

  ! Set up the unstructure grid index of the watch point.
  mosaic_tile_ug = lnd%ug_face
  watch_point_lindex = 0
  do l = lnd%ls, lnd%le
     if(watch_point(1) == lnd%i_index(l) .AND. watch_point(2) == lnd%j_index(l)) then
        watch_point_lindex = l
     endif
  enddo
  call mpp_max(watch_point_lindex)

end subroutine land_debug_init

! ============================================================================
subroutine land_debug_end()
  deallocate(curr_i,curr_j,curr_k,curr_l)
  deallocate(current_debug_level)
end subroutine

! ============================================================================
subroutine set_current_point_sg(i,j,k,l)
  integer, intent(in) :: i,j,k,l

  integer :: thread, my_mosaic_tile
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1

  curr_i(thread) = i ; curr_j(thread) = j ; curr_k(thread) = k; curr_l(thread) = l
  if(l==0) then
     my_mosaic_tile = mosaic_tile_sg
  else
     my_mosaic_tile = mosaic_tile_ug
  endif

  current_debug_level(thread) = 0
  if ( watch_point(1)==i.and. &
       watch_point(2)==j.and. &
       watch_point(3)==k.and. &
       watch_point(4)==my_mosaic_tile) then
     current_debug_level(thread) = 1
  endif
end subroutine set_current_point_sg

! ============================================================================
subroutine set_current_point_ug(l,k)
  integer, intent(in) :: l,k

  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1
  curr_i(thread) = lnd%i_index(l) ; curr_j(thread) = lnd%j_index(l)
  curr_k(thread) = k; curr_l(thread) = l

  current_debug_level(thread) = 0
  if ( watch_point_lindex==l.and. &
       watch_point(3)==k.and. &
       watch_point(4)==mosaic_tile_ug) then
     current_debug_level(thread) = 1
  endif
end subroutine set_current_point_ug

! ============================================================================
subroutine get_current_point(i,j,k,face)
  integer, intent(out), optional :: i,j,k,face

  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1

  if (present(i)) i = curr_i(thread)
  if (present(j)) j = curr_j(thread)
  if (present(k)) k = curr_k(thread)
  if (present(face)) face = mosaic_tile_ug
end subroutine get_current_point

! ============================================================================
integer function current_i()
  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1
  current_i = curr_i(thread)
end function

integer function current_j()
  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1
  current_j = curr_j(thread)
end function

integer function current_k()
  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1
  current_k = curr_k(thread)
end function

integer function current_face() ; current_face = mosaic_tile_ug ; end function

! ============================================================================
function is_watch_time()
   logical :: is_watch_time
   is_watch_time = lnd%time >= start_watch_time &
             .and. lnd%time <= stop_watch_time
end function is_watch_time

! ============================================================================
function is_watch_point()
  logical :: is_watch_point

  integer :: thread
    thread = 1
!$  thread = OMP_GET_THREAD_NUM()+1
  is_watch_point = (current_debug_level(thread) > 0 .and. is_watch_time())
end function is_watch_point

! ============================================================================
! returns true, if the watch point is within the grid cell, regardless of
! the tile number
function is_watch_cell()
  logical :: is_watch_cell
  is_watch_cell = ( current_i() == watch_point(1) &
              .and. current_j() == watch_point(2) &
              .and. mosaic_tile_ug == watch_point(4) &
              .and. is_watch_time()               )
end function is_watch_cell


! ============================================================================
subroutine get_watch_point(i,j,k,face,l)
  integer, intent(out), optional :: i,j,k,face,l
  if (present(i)) i = watch_point(1)
  if (present(j)) j = watch_point(2)
  if (present(k)) k = watch_point(3)
  if (present(face)) face = watch_point(4)
  if (present(l)) l = watch_point_lindex
end subroutine get_watch_point

! ============================================================================
! checks if the temperature within reasonable range, and prints a message
! if it isn't
subroutine check_temp_range_0d(temp, tag, varname)
  real, intent(in) :: temp ! temperature to check
  character(*), intent(in) :: tag ! tag to print
  character(*), intent(in) :: varname ! name of the variable for printout

  call check_var_range(temp,temp_lo,temp_hi,tag,varname,WARNING)
end subroutine check_temp_range_0d

subroutine check_temp_range_1d(temp, tag, varname)
  real, intent(in) :: temp(:) ! temperature to check
  character(*), intent(in) :: tag ! tag to print
  character(*), intent(in) :: varname ! name of the variable for printout

  call check_var_range(temp,temp_lo,temp_hi,tag,varname,WARNING)
end subroutine check_temp_range_1d

! ============================================================================
! checks if the value is within specified range, and prints a message
! if it isn't
subroutine check_var_range_0d(value, lo, hi, tag, varname, severity)
  real        , intent(in) :: value    ! value to check
  real        , intent(in) :: lo,hi    ! lower and upper bounds of acceptable range
  character(*), intent(in) :: tag      ! tag to print
  character(*), intent(in) :: varname  ! name of the variable for printout
  integer     , intent(in) :: severity ! severity of the non-conservation error:
         ! Can be WARNING, FATAL, or negative. Negative means check is not done.

  ! ---- local vars
  integer :: y,mo,d,h,m,s ! components of date
  integer :: thread, face
  real    :: lon, lat ! current coordinates, degree
  character(512) :: message

  if (severity<0) return

  if(lo<=value.and.value<=hi) then
     return
  else
     thread = 1
!$   thread = OMP_GET_THREAD_NUM()+1
     call get_date(lnd%time,y,mo,d,h,m,s)
     call get_current_coordinates(thread, lon, lat, face)

     write(message,'(a,g23.16,2(x,a,f9.4),4(x,a,i4),x,a,i4.4,2("-",i2.2),x,i2.2,2(":",i2.2))')&
          trim(varname)//' out of range: value=', value, 'at lon=',lon, 'lat=',lat, &
          'i=',curr_i(thread),'j=',curr_j(thread),'tile=',curr_k(thread),'face=',face, &
          'time=',y,mo,d,h,m,s
     call error_mesg(trim(tag),message,severity)
  endif
end subroutine check_var_range_0d


! ============================================================================
subroutine check_var_range_1d(value, lo, hi, tag, varname, severity)
  real        , intent(in) :: value(:) ! value to check
  real        , intent(in) :: lo,hi    ! lower and upper bounds of acceptable range
  character(*), intent(in) :: tag      ! tag to print
  character(*), intent(in) :: varname  ! name of the variable for printout
  integer     , intent(in) :: severity ! severity of the non-conservation error:
         ! Can be WARNING, FATAL, or negative. Negative means check is not done.

  ! ---- local vars
  integer :: i
  integer :: y,mo,d,h,m,s ! components of date
  integer :: thread, face
  real    :: lon, lat ! current coordinates, degree
  character(512) :: message

  if (severity<0) return

  do i = 1,size(value)
     if(lo<=value(i).and.value(i)<=hi) then
        cycle
     else
        thread = 1
!$      thread = OMP_GET_THREAD_NUM()+1
        call get_date(lnd%time,y,mo,d,h,m,s)
        call get_current_coordinates(thread, lon, lat, face)
        write(message,'(a,g23.16,2(x,a,f9.4),4(x,a,i4),x,a,i4.4,2("-",i2.2),x,i2.2,2(":",i2.2))')&
             trim(varname)//'('//trim(string(i))//')'//' out of range: value=', value(i),&
             'at lon=',lon, 'lat=',lat, &
             'i=',curr_i(thread),'j=',curr_j(thread),'tile=',curr_k(thread),'face=',face, &
             'time=',y,mo,d,h,m,s
        call error_mesg(trim(tag),message,severity)
     endif
  enddo
end subroutine check_var_range_1d


! ============================================================================
! debug printout procedures
subroutine debug_printout_r0d(description,value)
  character(*), intent(in) :: description
  real        , intent(in) :: value

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description),value
  else
     write(*,'(x,a,g23.16)',advance='NO')trim(description),value
  endif
  if(print_hex_debug) write(*,'(z17)',advance='NO')value
end subroutine


subroutine debug_printout_i0d(description,value)
  character(*), intent(in) :: description
  integer     , intent(in) :: value

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description),value
  else
     write(*,'(x,a,g23.16)',advance='NO')trim(description),value
  endif
end subroutine


subroutine debug_printout_l0d(description,value)
  character(*), intent(in) :: description
  logical     , intent(in) :: value

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description),value
  else
     write(*,'(x,a,g23.16)',advance='NO')trim(description),value
  endif
end subroutine


subroutine debug_printout_r1d(description,values)
  character(*), intent(in) :: description
  real        , intent(in) :: values(:)

  integer :: i

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description)
  else
     write(*,'(x,a)',advance='NO')trim(description)
  endif
  do i = 1,size(values)
     write(*,'(g23.16)',advance='NO')values(i)
     if(print_hex_debug) write(*,'(z17)',advance='NO')values(i)
  enddo
end subroutine

subroutine debug_printout_i1d(description,values)
  character(*), intent(in) :: description
  integer     , intent(in) :: values(:)

  integer :: i

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description),values
  else
     write(*,'(x,a,99g23.16)',advance='NO')trim(description),values
  endif
end subroutine

subroutine debug_printout_r2d(description,values)
  character(*), intent(in) :: description
  real        , intent(in) :: values(:,:)

  if (trim_labels.or.len_trim(description)<label_len) then
     write(*,fixed_format,advance='NO')trim(description),values
  else
     write(*,'(x,a,99g23.16)',advance='NO')trim(description),values
  endif
  ! TODO: print values as a matrix
end subroutine


! ============================================================================
! checks the conservation of a substance and issues a message with specified
! severity if the difference is not within tolerance.
subroutine check_conservation(tag, substance, d1, d2, tolerance, severity)
  character(*), intent(in) :: tag ! message tag (subroutine name or some such)
  character(*), intent(in) :: substance ! name of the substance for printout
  real, intent(in) :: d1,d2 ! values to check
  real, intent(in) :: tolerance ! tolerance of the test
  integer, intent(in), optional :: severity ! severity of the non-conservation error:
         ! Can be WARNING, FATAL, or negative. Negative means check is not done.

  ! ---- local vars
  integer :: y,mo,d,h,m,s ! components of date
  integer :: thread, face
  real    :: lon, lat ! current coordinates, degree
  character(512) :: message
  integer :: severity_

  if(.not.do_check_conservation) return

  severity_=FATAL
  if (present(severity))severity_=severity

  if (severity_<0) return

  if (abs(d2-d1)<tolerance) then
     if (is_watch_point().and.watch_conservation) then
     write(*,'(3(x,a,g23.16))')&
          trim(tag)//': conservation of '//trim(substance)//'; before=', d1, 'after=', d2, 'diff=',d2-d1
     endif
  else
     thread = 1
!$   thread = OMP_GET_THREAD_NUM()+1
     call get_date(lnd%time,y,mo,d,h,m,s)
     call get_current_coordinates(thread, lon, lat, face)
     write(message,'(3(x,a,g23.16),2(x,a,f9.4),4(x,a,i4),x,a,i4.4,2("-",i2.2),x,i2.2,2(":",i2.2))')&
          'conservation of '//trim(substance)//' is violated; before=', d1, 'after=', d2, 'diff=',d2-d1,&
          'at lon=',lon, 'lat=',lat, &
          'i=',curr_i(thread),'j=',curr_j(thread),'tile=',curr_k(thread),'face=',mosaic_tile_ug, &
          'time=',y,mo,d,h,m,s
     call error_mesg(tag,message,severity_)
  endif
end subroutine check_conservation

! returns coordinates and face of current point
subroutine get_current_coordinates(thread, lon, lat, face)
   integer, intent(in)  :: thread   ! our thread
   real, intent(out)    :: lon, lat ! coordinates of current point, degree
   integer, intent(out) :: face     ! number of cubic sphere face

   if(curr_l(thread) == 0) then
      lon = lnd%sg_lon(curr_i(thread),curr_j(thread))*180.0/PI
      lat = lnd%sg_lat(curr_i(thread),curr_j(thread))*180.0/PI
      face = mosaic_tile_sg
   else
      lon = lnd%ug_lon(curr_l(thread))*180.0/PI
      lat = lnd%ug_lat(curr_l(thread))*180.0/PI
      face = mosaic_tile_ug
   endif
end subroutine get_current_coordinates

! ============================================================================
! print a message with current coordinates and time
subroutine land_error_message(text,severity)
  character(*), intent(in) :: text
  integer, intent(in), optional :: severity

  integer :: y,mo,d,h,m,s ! components of date
  real    :: lon, lat ! current coordinates, degree
  integer :: thread, face
  character(512) :: message
  integer :: severity_

  severity_=WARNING
  if (present(severity))severity_=severity

  thread = 1
!$   thread = OMP_GET_THREAD_NUM()+1
  call get_date(lnd%time,y,mo,d,h,m,s)
  call get_current_coordinates(thread, lon, lat, face)
  write(message,'(2(x,a,f9.4),4(x,a,i4),x,a,i4.4,2("-",i2.2),x,i2.2,2(":",i2.2))') &
       'at lon=',lon, 'lat=',lat, &
       'i=',curr_i(thread),'j=',curr_j(thread),'tile=',curr_k(thread),'face=',face, &
       'time=',y,mo,d,h,m,s
  call error_mesg(text,message,severity_)

end subroutine land_error_message

! ============================================================================
! print time in the debug output
subroutine log_date(tag,time)
  character(*),    intent(in) :: tag
  type(time_type), intent(in) :: time
  integer :: y,mo,d,h,m,s ! components of date for debug printout

  call get_date(lnd%time,y,mo,d,h,m,s)
  write(*,'(a,i4.4,2("-",i2.2),x,i2.2,2(":",i2.2))') tag,y,mo,d,h,m,s
end subroutine log_date

end module land_debug_mod
