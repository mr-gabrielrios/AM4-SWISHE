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
!> @defgroup mpp_utilities_mod mpp_utilities_mod
!> @ingroup mpp
!> @brief Module for utiltity routines to be used in @ref mpp modules
!!
!> Currently only holds one routine for finding global min and max

!> @file
!> @brief File for @ref mpp_utilities_mod

!> @addtogroup mpp_utilities_mod
!> @{
module mpp_utilities_mod

implicit none
!-----------------------------------------------------------------------
! Include variable "version" to be written to log file.
#include<file_version.h>
!-----------------------------------------------------------------------

  public :: mpp_array_global_min_max

contains

!#######################################################################
!> @brief Compute and return the global min and max of an array
!! and the corresponding lat-lon-depth locations .
!!
!> This algorithm works only for an input array that has a unique global
!! max and min location. This is assured by introducing a factor that distinguishes
!! the values of extrema at each processor.
!!
!! Vectorized using maxloc() and minloc() intrinsic functions by
!! Russell.Fiedler@csiro.au (May 2005).
!!
!! Modified by Zhi.Liang@noaa.gov (July 2005)
!!
!! Modified by Niki.Zadeh@noaa.gov (Feb. 2009)
!!
subroutine mpp_array_global_min_max(in_array, tmask,isd,jsd,isc,iec,jsc,jec,nk, g_min, g_max, &
                                    geo_x,geo_y,geo_z, xgmin, ygmin, zgmin, xgmax, ygmax, zgmax)

  use mpp_mod,           only: mpp_min, mpp_max, mpp_pe, mpp_sum

  integer,                      intent(in) :: isd,jsd,isc,iec,jsc,jec,nk
  real, dimension(isd:,jsd:,:), intent(in) :: in_array
  real, dimension(isd:,jsd:,:), intent(in) :: tmask
  real,                         intent(out):: g_min, g_max
  real, dimension(isd:,jsd:),   intent(in) :: geo_x,geo_y
  real, dimension(:),           intent(in) :: geo_z
  real,                         intent(out):: xgmin, ygmin, zgmin, xgmax, ygmax, zgmax

  real    :: tmax, tmin, tmax0, tmin0
  integer :: itmax, jtmax, ktmax, itmin, jtmin, ktmin
  real    :: fudge

  ! arrays to enable vectorization
  integer :: iminarr(3),imaxarr(3)

  g_min=-88888888888.0 ; g_max=-999999999.0

  tmax=-1.e10;tmin=1.e10
  itmax=0;jtmax=0;ktmax=0
  itmin=0;jtmin=0;ktmin=0

  if(ANY(tmask(isc:iec,jsc:jec,:) > 0.)) then
     iminarr=minloc(in_array(isc:iec,jsc:jec,:),tmask(isc:iec,jsc:jec,:) > 0.)
     imaxarr=maxloc(in_array(isc:iec,jsc:jec,:),tmask(isc:iec,jsc:jec,:) > 0.)
     itmin=iminarr(1)+isc-1
     jtmin=iminarr(2)+jsc-1
     ktmin=iminarr(3)
     itmax=imaxarr(1)+isc-1
     jtmax=imaxarr(2)+jsc-1
     ktmax=imaxarr(3)
     tmin=in_array(itmin,jtmin,ktmin)
     tmax=in_array(itmax,jtmax,ktmax)
  end if

  ! use "fudge" to distinguish processors when tracer extreme is independent of processor
  fudge = 1.0 + 1.e-12*real(mpp_pe() )
  tmax = tmax*fudge
  tmin = tmin*fudge
  if(tmax == 0.0) then
    tmax = tmax + 1.e-12*real(mpp_pe() )
  endif
  if(tmin == 0.0) then
    tmin = tmin + 1.e-12*real(mpp_pe() )
  endif


  tmax0=tmax;tmin0=tmin

  call mpp_max(tmax)
  call mpp_min(tmin)

  g_max = tmax
  g_min = tmin

  !Now find the location of the global extrema.
  !
  !Note that the fudge factor above guarantees that the location of max (min) is uinque,
  ! since tmax0 (tmin0) has slightly different values on each processor.
  !Otherwise, the function in_array(i,j,k) could be equal to global max (min) at more
  ! than one point in space and this would be a much more difficult problem to solve.
  !
  !mpp_max trick
  !-999 on all current PE's
  xgmax=-999.; ygmax=-999.; zgmax=-999.
  xgmin=-999.; ygmin=-999.; zgmin=-999.


  !except when
  if (tmax0 == tmax) then !This happens ONLY on ONE processor because of fudge factor above.
     xgmax=geo_x(itmax,jtmax)
     ygmax=geo_y(itmax,jtmax)
     zgmax=geo_z(ktmax)
  endif

  call mpp_max(xgmax)
  call mpp_max(ygmax)
  call mpp_max(zgmax)

  if (tmin0 == tmin) then !This happens ONLY on ONE processor because of fudge factor above.
     xgmin=geo_x(itmin,jtmin)
     ygmin=geo_y(itmin,jtmin)
     zgmin=geo_z(ktmin)
  endif

  call mpp_max(xgmin)
  call mpp_max(ygmin)
  call mpp_max(zgmin)

  return


end subroutine mpp_array_global_min_max
! </SUBROUTINE>  NAME="mpp_array_global_min_max"



end module mpp_utilities_mod
!> @}
! close documentation grouping
