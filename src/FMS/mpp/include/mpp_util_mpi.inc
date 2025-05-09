! -*-f90-*-

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
!> @file
!> @ingroup mpp
!> @brief Utility routines for parallelization with MPI

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!                                                                             !
!         MISCELLANEOUS UTILITIES: mpp_error                                  !
!                                                                             !
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

!> A very basic error handler
!! uses ABORT and FLUSH calls, may need to use cpp to rename
subroutine mpp_error_basic( errortype, errormsg )
#ifdef __INTEL_COMPILER
  ! Intel module containing tracebackQQ
   use ifcore
#endif
  integer,                    intent(in) :: errortype
  character(len=*), intent(in), optional :: errormsg
  character(len=512)                     :: text
  integer                                :: errunit

  if( .NOT.module_is_initialized )call ABORT()

  select case( errortype )
  case(NOTE)
     text = 'NOTE'         !just FYI
  case(WARNING)
     text = 'WARNING'      !probable error
  case(FATAL)
     text = 'FATAL'        !fatal error
  case default
     text = 'WARNING: non-existent errortype (must be NOTE|WARNING|FATAL)'
  end select

  if( npes.GT.1 )write( text,'(a,i6)' )trim(text)//' from PE', pe   !this is the mpp part
  if( PRESENT(errormsg) )text = trim(text)//': '//trim(errormsg)
!$OMP CRITICAL (MPP_ERROR_CRITICAL)
  select case( errortype )
  case(NOTE)
     if(pe==root_pe)write( out_unit,'(a)' )trim(text)
  case default
     errunit = stderr()
     write( errunit, '(/a/)' )trim(text)
     if(pe==root_pe)write( out_unit,'(/a/)' )trim(text)
     if( errortype.EQ.FATAL .OR. warnings_are_fatal )then
        FLUSH(out_unit)
#ifdef __INTEL_COMPILER
  ! Get traceback and return quietly for correct abort
        call TRACEBACKQQ(user_exit_code=-1)
#elif __GFORTRAN__
        call BACKTRACE
#endif
        call MPI_ABORT( MPI_COMM_WORLD, 1, error )
     end if
  end select

  error_state = errortype
!$OMP END CRITICAL (MPP_ERROR_CRITICAL)


end subroutine mpp_error_basic

!#####################################################################
!> Makes a PE set out of a PE list. A PE list is an ordered list of PEs
!! a PE set is a triad (start,log2stride,size) for SHMEM, an a communicator for MPI
!! if stride is non-uniform or not a power of 2,
!! will return error (not required for MPI but enforced for uniformity)
function get_peset(pelist)
  integer                       :: get_peset
  integer, intent(in), optional :: pelist(:)
  integer                       :: errunit
  integer                       :: i, n
  integer,          allocatable :: sorted(:)

  if( .NOT.PRESENT(pelist) )then !set it to current_peset_num
     get_peset = current_peset_num; return
  end if

  !--- first make sure pelist is monotonically increasing.
  if (size(pelist(:)) .GT. 1) then
    do n = 2, size(pelist(:))
       if(pelist(n) <= pelist(n-1)) call mpp_error(FATAL, "GET_PESET: pelist is not monotonically increasing")
    enddo
  endif

  allocate( sorted(size(pelist(:))) )
  sorted = pelist
  errunit = stderr()
  if( debug )write( errunit,* )'pelist=', pelist

  !find if this array matches any existing peset
  do i = 1,peset_num
     if( debug )write( errunit,'(a,3i6)' )'pe, i, peset_num=', pe, i, peset_num
     if( size(sorted(:)).EQ.size(peset(i)%list(:)) )then
        if( ALL(sorted.EQ.peset(i)%list) )then
           deallocate(sorted)
           get_peset = i; return
        end if
     end if
  end do
  !not found, so create new peset
  peset_num = peset_num + 1
  if( peset_num > current_peset_max ) call expand_peset()
  i = peset_num             !shorthand
  !create list
  allocate( peset(i)%list(size(sorted(:))) )
  peset(i)%list(:) = sorted(:)
  peset(i)%count = size(sorted(:))

  call MPI_GROUP_INCL( peset(current_peset_num)%group, size(sorted(:)), sorted-mpp_root_pe(), peset(i)%group, error )
  call MPI_COMM_CREATE_GROUP(peset(current_peset_num)%id, peset(i)%group, &
                             DEFAULT_TAG, peset(i)%id, error )
  deallocate(sorted)
  get_peset = i

  return

end function get_peset

!#######################################################################
!> Synchronize PEs in list
subroutine mpp_sync( pelist, do_self )
  integer, intent(in), optional :: pelist(:)
  logical, intent(in), optional :: do_self
  logical                       :: dself
  integer                       :: n

  dself=.true.; if(PRESENT(do_self))dself=do_self
!  if(dself)call mpp_sync_self(pelist)

  n = get_peset(pelist); if( peset(n)%count.EQ.1 )return

  if( debug .and. (current_clock.NE.0) )call SYSTEM_CLOCK(start_tick)
  call MPI_BARRIER( peset(n)%id, error )

  if( debug .and. (current_clock.NE.0) )call increment_current_clock(EVENT_WAIT)

  return
end subroutine mpp_sync

!#######################################################################
!> This is to check if current PE's outstanding puts are complete
!! but we can't use shmem_fence because we are actually waiting for
!! a remote PE to complete its get
subroutine mpp_sync_self( pelist, check, request, msg_size, msg_type)
  integer, intent(in), optional :: pelist(:)
  integer, intent(in), optional :: check
  integer, intent(inout), optional :: request(:)
  integer, intent(in   ), optional :: msg_size(:)
  integer, intent(in   ), optional :: msg_type(:)

  integer                       :: m, my_check, rsize

  if( debug .and. (current_clock.NE.0) )call SYSTEM_CLOCK(start_tick)
  my_check = EVENT_SEND
  if(present(check)) my_check = check
  if( my_check .NE. EVENT_SEND .AND. my_check .NE. EVENT_RECV ) then
     call mpp_error( FATAL, 'mpp_sync_self: The value of optional argument check should be EVENT_SEND or EVENT_RECV')
  endif

  if(PRESENT(request)) then
     if( .not. present(check) ) then
        call mpp_error(FATAL, 'mpp_sync_self: check is not present when request is present')
     endif
     if( my_check == EVENT_RECV ) then
        if( .not. present(msg_size) ) then
           call mpp_error(FATAL, 'mpp_sync_self: msg_size is not present when request is present and it is EVENT_RECV')
        endif
        if( .not. present(msg_type) ) then
           call mpp_error(FATAL, 'mpp_sync_self: msg_type is not present when request is present and it is EVENT_RECV')
        endif
        if(size(msg_size) .NE. size(request)) then
           call mpp_error(FATAL, 'mpp_sync_self: dimension mismatch between msg_size and request')
        endif
        if(size(msg_type) .NE. size(request)) then
           call mpp_error(FATAL, 'mpp_sync_self: dimension mismatch between msg_type and request')
        endif

        do m = 1, size(request(:))
           if( request(m) == MPI_REQUEST_NULL ) cycle
           call MPI_WAIT(request(m), stat, error )
           call MPI_GET_COUNT(stat, msg_type(m), rsize, error)
           if(msg_size(m) .NE. rsize) then
                call mpp_error(FATAL, "mpp_sync_self: msg_size does not match size of data received")
           endif
        enddo
     else
        do m = 1, size(request(:))
           if(request(m) .NE.MPI_REQUEST_NULL )call MPI_WAIT(request(m), stat, error )
        enddo
     endif
  else
     select case(my_check)
     case(EVENT_SEND)
        do m = 1,cur_send_request
           if( request_send(m).NE.MPI_REQUEST_NULL )call MPI_WAIT( request_send(m), stat, error )
        end do
        cur_send_request = 0
     case(EVENT_RECV)
        do m = 1,cur_recv_request
           call MPI_WAIT( request_recv(m), stat, error )
           call MPI_GET_COUNT(stat, type_recv(m), rsize, error)
           if(size_recv(m) .NE. rsize) then
                call mpp_error(FATAL, "mpp_sync_self: size_recv does not match of data received")
           endif
           size_recv(m) = 0
        end do
        cur_recv_request = 0
     end select
  endif
  if( debug .and. (current_clock.NE.0) )call increment_current_clock(EVENT_WAIT)
  return
end subroutine mpp_sync_self
