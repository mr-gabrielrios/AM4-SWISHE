!***********************************************************************
!*                   GNU Lesser General Public License
!*
!* This file is part of the GFDL Flexible Modeling System (FMS).
!*
!* FMS is free software: you can redistribute it and/or modify it under
!* the terms of the GNU Lesser General Public License as published by
!* the Free Software Foundation, either version 3 of the License, or (at
!* your option) any later version.
!*
!* FMS is distributed in the hope that it will be useful, but WITHOUT
!* ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
!* FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
!* for more details.
!*
!* You should have received a copy of the GNU Lesser General Public
!* License along with FMS.  If not, see <http://www.gnu.org/licenses/>.
!***********************************************************************
!> @defgroup column_diagnostics_mod column_diagnostics_mod
!> @ingroup column_diagnostics
!! @brief Module to locate and mark desired diagnostic columns

!> @file
!> @brief File for @ref column_diagnostics_mod

!> @addtogroup column_diagnostics_mod
!> @{
module column_diagnostics_mod

use fms_mod,                only:  fms_init, mpp_pe, mpp_root_pe, &
                                   mpp_npes, check_nml_error, &
                                   error_mesg, FATAL, NOTE, WARNING, &
                                   stdlog, write_version_number
use time_manager_mod,       only:  time_manager_init, month_name, &
                                   get_date, time_type
use constants_mod,          only:  constants_init, PI, RADIAN
use mpp_mod,                only:  input_nml_file

!-------------------------------------------------------------------

implicit none
private

!---------------------------------------------------------------------
!      module to locate and mark desired diagnostic columns
!
!
!--------------------------------------------------------------------




!---------------------------------------------------------------------
!----------- ****** VERSION NUMBER ******* ---------------------------


! Include variable "version" to be written to log file.
#include<file_version.h>



!---------------------------------------------------------------------
!-------  interfaces --------

public    column_diagnostics_init,  &
          initialize_diagnostic_columns,  &
          column_diagnostics_header,   &
          close_column_diagnostics_units

!private

!--------------------------------------------------------------------
!----    namelist -----

real          :: crit_xdistance = 4.0 !< model grid points must be within crit_xdistance in
                                      !! longitude of the requested diagnostics point
                                      !! coordinates in order to be flagged as the desired
                                      !! point
                                      !! [ degrees ]
real          :: crit_ydistance = 4.0 !< model grid points must be within crit_ydistance in
                                      !! latitude of the requested diagnostics point
                                      !! coordinates in order to be flagged as the desired
                                      !! point
                                      !! [ degrees ]

namelist / column_diagnostics_nml /              &
                                      crit_xdistance, &
                                      crit_ydistance

!--------------------------------------------------------------------
!-------- public data  -----


!--------------------------------------------------------------------
!------ private data ------


logical    :: module_is_initialized = .false.

!-------------------------------------------------------------------
!-------------------------------------------------------------------



                        contains



!####################################################################

!> @brief Initialization routine for column_diagnostics_mod.
!!
!> Reads namelist and writes to log.
subroutine column_diagnostics_init

!--------------------------------------------------------------------
!    column_diagnostics_init is the constructor for
!    column_diagnostics_mod.
!--------------------------------------------------------------------

!--------------------------------------------------------------------
!    local variables:
!
      integer    :: unit !< unit number for nml file
      integer    :: ierr !< error return flag
      integer    :: io   !< error return code

!--------------------------------------------------------------------
!   local variables:
!
!       unit       unit number for nml file
!       ierr       error return flag
!       io         error return code
!
!---------------------------------------------------------------------

!--------------------------------------------------------------------
!    if routine has already been executed, return.
!--------------------------------------------------------------------
      if (module_is_initialized) return

!---------------------------------------------------------------------
!    verify that all modules used by this module have been initialized.
!----------------------------------------------------------------------
      call fms_init
      call time_manager_init
      call constants_init

!---------------------------------------------------------------------
!    read namelist.
!---------------------------------------------------------------------
      read (input_nml_file, column_diagnostics_nml, iostat=io)
      ierr = check_nml_error (io, 'column_diagnostics_nml')
!---------------------------------------------------------------------
!    write version number and namelist to logfile.
!---------------------------------------------------------------------
      call write_version_number("COLUMN_DIAGNOSTICS_MOD", version)
      if (mpp_pe() == mpp_root_pe())    then
                    unit = stdlog()
                    write (unit, nml=column_diagnostics_nml)
      endif
!--------------------------------------------------------------------
      module_is_initialized = .true.


end subroutine column_diagnostics_init



!####################################################################

!> @brief initialize_diagnostic_columns returns the (i, j, lat, lon) coord-
!!    inates of any diagnostic columns that are located on the current
!!    processor.
subroutine initialize_diagnostic_columns     &
                   (module, num_diag_pts_latlon, num_diag_pts_ij,  &
                    global_i , global_j , global_lat_latlon,   &
                    global_lon_latlon, lonb_in, latb_in,  &
                    do_column_diagnostics,  &
                    diag_lon, diag_lat, diag_i, diag_j, diag_units)

!---------------------------------------------------------------------
!    initialize_diagnostic_columns returns the (i, j, lat, lon) coord-
!    inates of any diagnostic columns that are located on the current
!    processor.
!----------------------------------------------------------------------

!---------------------------------------------------------------------
character(len=*),      intent(in)    :: module                !< module calling this subroutine
integer,               intent(in)    :: num_diag_pts_latlon   !< number of diagnostic columns specified
                                                              !! by lat-lon  coordinates
integer,               intent(in)    :: num_diag_pts_ij       !< number of diagnostic columns specified
                                                              !! by global (i,j) coordinates
integer, dimension(:), intent(in)    :: global_i              !< specified global i coordinates
integer, dimension(:), intent(in)    :: global_j              !< specified global j coordinates
real   , dimension(:), intent(in)    :: global_lat_latlon     !< specified global lat coordinates
real   , dimension(:), intent(in)    :: global_lon_latlon     !< specified global lon coordinates
real,    dimension(:,:), intent(in)  :: lonb_in, latb_in
logical, dimension(:,:), intent(out) :: do_column_diagnostics !< is a diagnostic column in this jrow ?
integer, dimension(:), intent(inout) :: diag_i                !< processor i indices of diagnstic columns
integer, dimension(:), intent(inout) :: diag_j                !< processor j indices of diagnstic columns
real   , dimension(:), intent(out)   :: diag_lat              !< latitudes of diagnostic columns [ degrees ]
real   , dimension(:), intent(out)   :: diag_lon              !< longitudes of diagnostic columns [ degrees ]
integer, dimension(:), intent(out)   :: diag_units            !< unit number for each diagnostic column
!---------------------------------------------------------------------

!---------------------------------------------------------------------
!    intent(in) variables:
!
!       module                module calling this subroutine
!       num_diag_pts_latlon   number of diagnostic columns specified
!                             by lat-lon  coordinates
!       num_diag_pts_ij       number of diagnostic columns specified
!                             by global (i,j) coordinates
!       global_i              specified global i coordinates
!       global_j              specified global j coordinates
!       global_lat_latlon     specified global lat coordinates
!       global_lon_latlon     specified global lon coordinates
!
!    intent(out) variables:
!
!       do_column_diagnostics is a diagnostic column in this jrow ?
!       diag_i                processor i indices of diagnstic columns
!       diag_j                processor j indices of diagnstic columns
!       diag_lat              latitudes of diagnostic columns
!                             [ degrees ]
!       diag_lon              longitudes of diagnostic columns
!                             [ degrees ]
!       diag_units            unit number for each diagnostic column
!
!---------------------------------------------------------------------

!--------------------------------------------------------------------
!    local variables:

      real, dimension(size(diag_i,1))     :: global_lat !< latitudes for all diagnostic columns [ degrees ]
      real, dimension(size(diag_i,1))     :: global_lon !< longitudes for all diagnostic columns [ degrees ]
      real, dimension(size(latb_in,1)-1, size(latb_in,2)-1) ::  &
                                  distance, distance_x, distance_y, &
                                   distance_x2, distance2
      real, dimension(size(latb_in,1), size(latb_in,2)) :: latb_deg
      real, dimension(size(lonb_in,1), size(lonb_in,2)) :: lonb_deg
      real       :: dellat, dellon
      real       :: latb_max, latb_min, lonb_max, lonb_min

      integer            ::  num_diag_pts !< total number of diagnostic columns
      integer            ::  i            !< do loop indices
      integer            ::  j            !< do loop indices
      integer            ::  nn           !< do loop indices
      real               ::  ref_lat
      real               ::  current_distance
      character(len=8)   ::  char         !< character string for diaganostic column index
      character(len=32)  ::  filename     !< filename for output file for diagnostic column
      logical            ::  allow_ij_input
      logical            ::  open_file
      integer            ::  io
!--------------------------------------------------------------------
!    local variables:
!
!       global_lat      latitudes for all diagnostic columns [ degrees ]
!       global_lon      longitudes for all diagnostic columns
!                       [ degrees ]
!       num_diag_pts    total number of diagnostic columns
!       i, j, nn        do loop indices
!       char            character string for diaganostic column index
!       filename        filename for output file for diagnostic column
!
!---------------------------------------------------------------------

      if (.not. module_is_initialized) call column_diagnostics_init

!--------------------------------------------------------------------
!    save the input lat and lon fields. define the delta of latitude
!    and longitude.
!--------------------------------------------------------------------
      latb_deg = latb_in*RADIAN
      lonb_deg = lonb_in*RADIAN
      dellat = latb_in(1,2) - latb_in(1,1)
      dellon = lonb_in(2,1) - lonb_in(1,1)
      latb_max = MAXVAL (latb_deg(:,:))
      latb_min = MINVAL (latb_deg(:,:))
      lonb_max = MAXVAL (lonb_deg(:,:))
      lonb_min = MINVAL (lonb_deg(:,:))
      if (lonb_min < 10.0 .or. lonb_max > 350.) then
        lonb_min = 0.
        lonb_max = 360.0
      endif

      allow_ij_input = .true.
      ref_lat = latb_in(1,1)
      do i =2,size(latb_in,1)
        if (latb_in(i,1) /= ref_lat) then
          allow_ij_input = .false.
          exit
        endif
      end do

      if ( .not. allow_ij_input .and. num_diag_pts_ij /= 0) then
        call error_mesg ('column_diagnostics_mod', &
        'cannot specify column diagnostics column with (i,j) &
           &coordinates when using cubed sphere -- must specify &
                                    & lat/lon coordinates', FATAL)
      endif

!----------------------------------------------------------------------
!    initialize column_diagnostics flag and diag unit numbers. define
!    total number of diagnostic columns.
!----------------------------------------------------------------------
      do_column_diagnostics = .false.
      diag_units(:) = -1
      diag_i(:) = -99
      diag_j(:) = -99
      diag_lat(:) = -999.
      diag_lon(:) = -999.
      num_diag_pts = size(diag_i(:))

!--------------------------------------------------------------------
!    define an array of lat-lon values for all diagnostic columns.
!--------------------------------------------------------------------
      do nn = 1, num_diag_pts_latlon
        global_lat(nn) = global_lat_latlon(nn)
        global_lon(nn) = global_lon_latlon(nn)
      end do

      do nn = 1, num_diag_pts_ij
        global_lat(nn+num_diag_pts_latlon) =    &
                         ((-0.5*acos(-1.0) + 0.5*dellat) + &
                         (global_j (nn)-1) *dellat)*RADIAN
        global_lon(nn+num_diag_pts_latlon) = (0.5*dellon +     &
                          (global_i (nn)-1)*dellon)*RADIAN
      end do

!----------------------------------------------------------------------
!    loop over all diagnostic points to check for their presence on
!    this processor.
!----------------------------------------------------------------------
      do nn=1,num_diag_pts
        open_file = .false.

!----------------------------------------------------------------------
!    verify that the values of lat and lon are valid.
!----------------------------------------------------------------------
        if (global_lon(nn) >= 0. .and. global_lon(nn) <= 360.0) then
        else
          call error_mesg ('column_diagnostics_mod', &
               ' invalid longitude', FATAL)
        endif
        if (global_lat(nn) >= -90.0 .and. global_lat(nn) <= 90.0) then
        else
          call error_mesg ('column_diagnostics_mod', &
               ' invalid latitude', FATAL)
        endif

!--------------------------------------------------------------------
!    if the desired diagnostics column is within the current
!    processor's domain, define the total and coordinate distances from
!    each of the processor's grid points to the diagnostics point.
!--------------------------------------------------------------------

        if (global_lat(nn) .ge. latb_min .and.  &
            global_lat(nn) .le. latb_max) then
          if (global_lon(nn) .ge. lonb_min     .and.&
              global_lon(nn) .le. lonb_max)  then
            do j=1,size(latb_deg,2) - 1
              do i=1,size(lonb_deg,1) - 1
                distance_y(i,j) = ABS(global_lat(nn) - latb_deg(i,j))
                distance_x(i,j) = ABS(global_lon(nn) - lonb_deg(i,j))
                distance_x2(i,j) = ABS((global_lon(nn)-360.) -  &
                                                       lonb_deg(i,j))
                distance(i,j) = (global_lat(nn) - latb_deg(i,j))**2 + &
                                (global_lon(nn) - lonb_deg(i,j))**2
                distance2(i,j) = (global_lat(nn) - latb_deg(i,j))**2 + &
                                 ((global_lon(nn)-360.) -    &
                                                   lonb_deg(i,j))**2
              end do
            end do

!--------------------------------------------------------------------
!    find the grid point on the processor that is within the specified
!    critical distance and also closest to the requested diagnostics
!    column. save the (i,j) coordinates and (lon,lat) of this model
!    grid point. set a flag indicating that a disgnostics file should
!    be opened on this processor for this diagnostic point.
!--------------------------------------------------------------------
            current_distance = distance(1,1)
            do j=1,size(latb_deg,2) - 1
              do i=1,size(lonb_deg,1) - 1
                if (distance_x(i,j) <= crit_xdistance .and. &
                    distance_y(i,j) <= crit_ydistance ) then
                  if (distance(i,j) < current_distance) then
                    current_distance = distance(i,j)
                    do_column_diagnostics(i,j) = .true.
                    diag_j(nn) = j
                    diag_i(nn) = i
                    diag_lon(nn) = lonb_deg(i,j)
                    diag_lat(nn) = latb_deg(i,j)
                    open_file = .true.
                  endif
                endif

!---------------------------------------------------------------------
!    check needed because of the 0.0 / 360.0 longitude periodicity.
!---------------------------------------------------------------------
                if (distance_x2(i,j) <= crit_xdistance .and. &
                    distance_y(i,j) <= crit_ydistance ) then
                  if (distance2(i,j) < current_distance) then
                    current_distance = distance2(i,j)
                    do_column_diagnostics(i,j) = .true.
                    diag_j(nn) = j
                    diag_i(nn) = i
                    diag_lon(nn) = lonb_deg(i,j)
                    diag_lat(nn) = latb_deg(i,j)
                    open_file = .true.
                  endif
                endif
              end do
            end do

!--------------------------------------------------------------------
!    if the point has been found on this processor, open a diagnostics
!    file.
!--------------------------------------------------------------------
            if (open_file) then
              write (char, '(i2)') nn
              filename = trim(module) // '_point' //    &
                         trim(adjustl(char)) // '.out'
              if(mpp_npes() > 10000) then
                 write( filename,'(a,i6.6)' )trim(filename)//'.', mpp_pe()-mpp_root_pe()
              else
                 write( filename,'(a,i4.4)' )trim(filename)//'.', mpp_pe()-mpp_root_pe()
              endif
              open(newunit=diag_units(nn), file=trim(filename), action='WRITE', position='rewind', iostat=io)
              if(io/=0) call error_mesg ('column_diagnostics_mod', 'Error in opening file '//trim(filename), FATAL)
            endif  ! (open_file)
          endif
        endif
      end do

!---------------------------------------------------------------------


end subroutine initialize_diagnostic_columns




!####################################################################
!> @brief column_diagnostics_header writes out information concerning
!!    time and location of following data into the column_diagnostics
!!    output file.
subroutine column_diagnostics_header     &
                              (module, diag_unit, Time, nn, diag_lon, &
                               diag_lat, diag_i, diag_j)

!--------------------------------------------------------------------
!    column_diagnostics_header writes out information concerning
!    time and location of following data into the column_diagnostics
!    output file.
!--------------------------------------------------------------------

!--------------------------------------------------------------------
character(len=*),      intent(in)  :: module    !< module name calling this subroutine
type(time_type),       intent(in)  :: Time      !< current model time [ time_type ]
integer,               intent(in)  :: diag_unit !< unit number for column_diagnostics output
integer,               intent(in)  :: nn        !< index of diagnostic column currently active
real,    dimension(:), intent(in)  :: diag_lon  !< longitude of current diagnostic column [ degrees ]
real,    dimension(:), intent(in)  :: diag_lat  !< latitude of current diagnostic column [ degrees ]
integer, dimension(:), intent(in)  :: diag_i    !< i coordinate of current diagnostic column
integer, dimension(:), intent(in)  :: diag_j    !< j coordinate of current diagnostic column

!--------------------------------------------------------------------
!    intent(in) variables
!
!       module     module name calling this subroutine
!       Time       current model time [ time_type ]
!       diag_unit  unit number for column_diagnostics output
!       nn         index of diagnostic column currently active
!       diag_lon   longitude of current diagnostic column [ degrees ]
!       diag_lat   latitude of current diagnostic column [ degrees ]
!       diag_i     i coordinate of current diagnostic column
!       diag_j     j coordinate of current diagnostic column
!
!---------------------------------------------------------------------

!--------------------------------------------------------------------
!     local variables:

      integer           :: year   !< integers defining the current time
      integer           :: month  !< integers defining the current time
      integer           :: day    !< integers defining the current time
      integer           :: hour   !< integers defining the current time
      integer           :: minute !< integers defining the current time
      integer           :: second !< integers defining the current time
      character(len=9)  :: mon    !< character string for the current month
      character(len=64) :: header !< title for the output

!--------------------------------------------------------------------
!     local variables:
!
!       year, month, day, hour, minute, seconds
!                      integers defining the current time
!       mon            character string for the current month
!       header         title for the output
!
!--------------------------------------------------------------------

      if (.not. module_is_initialized) call column_diagnostics_init

!--------------------------------------------------------------------
!    convert the time type to a date and time for printing. convert
!    month to a character string.
!--------------------------------------------------------------------
      call get_date (Time, year, month, day, hour, minute, second)
      mon = month_name(month)

!---------------------------------------------------------------------
!    write timestamp and column location information to the diagnostic
!    columns output unit.
!---------------------------------------------------------------------
      write (diag_unit,'(a)')  ' '
      write (diag_unit,'(a)')  ' '
      write (diag_unit,'(a)')   &
              '======================================================'
      write (diag_unit,'(a)')  ' '
      header = '               PRINTING ' // module // '  DIAGNOSTICS'
      write (diag_unit,'(a)')  header
      write (diag_unit,'(a)')  ' '
      write (diag_unit,'(a, i6,2x, a,i4,i4,i4,i4)')  ' time stamp:',  &
                                           year, trim(mon), day, &
                                           hour, minute, second
      write (diag_unit,'(a, i4)')      &
            ' DIAGNOSTIC POINT COORDINATES, point #', nn
      write (diag_unit,'(a)')  ' '
      write (diag_unit,'(a,f8.3,a,f8.3)') ' longitude = ',    &
                   diag_lon(nn), ' latitude  = ', diag_lat(nn)
      write (diag_unit,'(a, i6, a,i6,a,i6)')    &
                               ' on processor # ', mpp_pe(),   &
                               ' :   processor i =', diag_i(nn),     &
                               ' ,   processor j =', diag_j(nn)
      write (diag_unit,'(a)')  ' '

!---------------------------------------------------------------------



end subroutine column_diagnostics_header



!######################################################################
!> @brief close_column_diagnostics_units closes any open column_diagnostics
!!    files associated with the calling module.
subroutine close_column_diagnostics_units (diag_units)

!---------------------------------------------------------------------
!    close_column_diagnostics_units closes any open column_diagnostics
!    files associated with the calling module.
!----------------------------------------------------------------------

!----------------------------------------------------------------------
integer, dimension(:), intent(in)  :: diag_units !< array of column diagnostic unit numbers
!----------------------------------------------------------------------

!--------------------------------------------------------------------
!    intent(in) variable:
!
!      diag_units    array of column diagnostic unit numbers
!
!--------------------------------------------------------------------

!--------------------------------------------------------------------
!    local variable

      integer   :: nn    !< do loop index
      integer   :: io
!--------------------------------------------------------------------
!    close the unit associated with each diagnostic column.
!--------------------------------------------------------------------
      do nn=1, size(diag_units(:))
        if (diag_units(nn) /= -1) then
          close(diag_units(nn), iostat=io )
          if(io/=0) call error_mesg('column_diagnostics_mod', 'Error in closing file ', FATAL)
        endif
      end do

!---------------------------------------------------------------------


end subroutine close_column_diagnostics_units


!#####################################################################




               end module column_diagnostics_mod
!@}
! close documentation grouping
