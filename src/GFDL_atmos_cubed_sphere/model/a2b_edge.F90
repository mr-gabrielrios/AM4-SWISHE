!***********************************************************************
!*                   GNU Lesser General Public License
!*
!* This file is part of the FV3 dynamical core.
!*
!* The FV3 dynamical core is free software: you can redistribute it
!* and/or modify it under the terms of the
!* GNU Lesser General Public License as published by the
!* Free Software Foundation, either version 3 of the License, or
!* (at your option) any later version.
!*
!* The FV3 dynamical core is distributed in the hope that it will be
!* useful, but WITHOUT ANYWARRANTY; without even the implied warranty
!* of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
!* See the GNU General Public License for more details.
!*
!* You should have received a copy of the GNU Lesser General Public
!* License along with the FV3 dynamical core.
!* If not, see <http://www.gnu.org/licenses/>.
!***********************************************************************
module a2b_edge_mod

  use fv_grid_utils_mod, only: great_circle_dist

  use fv_arrays_mod,     only: fv_grid_type, R_GRID

  implicit none

  real, parameter:: r3 = 1./3.
!----------------------------
! 4-pt Lagrange interpolation
!----------------------------
  real, parameter:: a1 =  0.5625  !  9/16
  real, parameter:: a2 = -0.0625  ! -1/16
!----------------------
! PPM volume mean form:
!----------------------
  real, parameter:: b1 =  7./12.     ! 0.58333333
  real, parameter:: b2 = -1./12.

  private
  public :: a2b_ord2, a2b_ord4

contains

  subroutine a2b_ord4(qin, qout, gridstruct, npx, npy, is, ie, js, je, ng, replace)
  integer, intent(IN):: npx, npy, is, ie, js, je, ng
  real, intent(INOUT)::  qin(is-ng:ie+ng,js-ng:je+ng)   ! A-grid field
  real, intent(INOUT):: qout(is-ng:ie+ng,js-ng:je+ng)   ! Output  B-grid field
  type(fv_grid_type), intent(IN), target :: gridstruct
  logical, optional, intent(IN):: replace
! local: compact 4-pt cubic
  real, parameter:: c1 =  2./3.
  real, parameter:: c2 = -1./6.
! Parabolic spline
! real, parameter:: c1 =  0.75
! real, parameter:: c2 = -0.25

  real qx(is:ie+1,js-ng:je+ng)
  real qy(is-ng:ie+ng,js:je+1)
  real qxx(is-ng:ie+ng,js-ng:je+ng)
  real qyy(is-ng:ie+ng,js-ng:je+ng)
  real g_in, g_ou
  real:: p0(2)
  real:: q1(is-1:ie+1), q2(js-1:je+1)
  integer:: i, j, is1, js1, is2, js2, ie1, je1

  real, pointer, dimension(:,:,:) :: grid, agrid
  real, pointer, dimension(:,:)   :: dxa, dya
  real(kind=R_GRID), pointer, dimension(:) :: edge_w, edge_e, edge_s, edge_n

  edge_w => gridstruct%edge_w
  edge_e => gridstruct%edge_e
  edge_s => gridstruct%edge_s
  edge_n => gridstruct%edge_n

  grid => gridstruct%grid
  agrid => gridstruct%agrid
  dxa => gridstruct%dxa
  dya => gridstruct%dya

  if (gridstruct%grid_type < 3) then

    is1 = max(1,is-1)
    js1 = max(1,js-1)
    is2 = max(2,is)
    js2 = max(2,js)

    ie1 = min(npx-1,ie+1)
    je1 = min(npy-1,je+1)

! Corners:
! 3-way extrapolation
    if (gridstruct%bounded_domain) then

    do j=js-2,je+2
       do i=is,ie+1
          qx(i,j) = b2*(qin(i-2,j)+qin(i+1,j)) + b1*(qin(i-1,j)+qin(i,j))
       enddo
    enddo


    else

    if ( gridstruct%sw_corner ) then
          p0(1:2) = grid(1,1,1:2)
        qout(1,1) = (extrap_corner(p0, agrid(1,1,1:2), agrid( 2, 2,1:2), qin(1,1), qin( 2, 2)) + &
                     extrap_corner(p0, agrid(0,1,1:2), agrid(-1, 2,1:2), qin(0,1), qin(-1, 2)) + &
                     extrap_corner(p0, agrid(1,0,1:2), agrid( 2,-1,1:2), qin(1,0), qin( 2,-1)))*r3

    endif
    if ( gridstruct%se_corner ) then
            p0(1:2) = grid(npx,1,1:2)
        qout(npx,1) = (extrap_corner(p0, agrid(npx-1,1,1:2), agrid(npx-2, 2,1:2), qin(npx-1,1), qin(npx-2, 2)) + &
                       extrap_corner(p0, agrid(npx-1,0,1:2), agrid(npx-2,-1,1:2), qin(npx-1,0), qin(npx-2,-1)) + &
                       extrap_corner(p0, agrid(npx  ,1,1:2), agrid(npx+1, 2,1:2), qin(npx  ,1), qin(npx+1, 2)))*r3
    endif
    if ( gridstruct%ne_corner ) then
              p0(1:2) = grid(npx,npy,1:2)
        qout(npx,npy) = (extrap_corner(p0, agrid(npx-1,npy-1,1:2), agrid(npx-2,npy-2,1:2), qin(npx-1,npy-1), qin(npx-2,npy-2)) + &
                         extrap_corner(p0, agrid(npx  ,npy-1,1:2), agrid(npx+1,npy-2,1:2), qin(npx  ,npy-1), qin(npx+1,npy-2)) + &
                         extrap_corner(p0, agrid(npx-1,npy  ,1:2), agrid(npx-2,npy+1,1:2), qin(npx-1,npy  ), qin(npx-2,npy+1)))*r3
    endif
    if ( gridstruct%nw_corner ) then
            p0(1:2) = grid(1,npy,1:2)
        qout(1,npy) = (extrap_corner(p0, agrid(1,npy-1,1:2), agrid( 2,npy-2,1:2), qin(1,npy-1), qin( 2,npy-2)) + &
                       extrap_corner(p0, agrid(0,npy-1,1:2), agrid(-1,npy-2,1:2), qin(0,npy-1), qin(-1,npy-2)) + &
                       extrap_corner(p0, agrid(1,npy,  1:2), agrid( 2,npy+1,1:2), qin(1,npy  ), qin( 2,npy+1)))*r3
    endif

!------------
! X-Interior:
!------------
    do j=max(1,js-2),min(npy-1,je+2)
       do i=max(3,is), min(npx-2,ie+1)
          qx(i,j) = b2*(qin(i-2,j)+qin(i+1,j)) + b1*(qin(i-1,j)+qin(i,j))
       enddo
    enddo

    ! *** West Edges:
    if ( is==1 ) then
       do j=js1, je1
          q2(j) = (qin(0,j)*dxa(1,j) + qin(1,j)*dxa(0,j))/(dxa(0,j) + dxa(1,j))
       enddo
       do j=js2, je1
          qout(1,j) = edge_w(j)*q2(j-1) + (1.-edge_w(j))*q2(j)
       enddo
!
       do j=max(1,js-2),min(npy-1,je+2)
             g_in = dxa(2,j) / dxa(1,j)
             g_ou = dxa(-1,j) / dxa(0,j)
          qx(1,j) = 0.5*( ((2.+g_in)*qin(1,j)-qin( 2,j))/(1.+g_in) +          &
                          ((2.+g_ou)*qin(0,j)-qin(-1,j))/(1.+g_ou) )
          qx(2,j) = ( 3.*(g_in*qin(1,j)+qin(2,j))-(g_in*qx(1,j)+qx(3,j)) ) / (2.+2.*g_in)
       enddo
    endif

    ! East Edges:
    if ( (ie+1)==npx ) then
       do j=js1, je1
          q2(j) = (qin(npx-1,j)*dxa(npx,j) + qin(npx,j)*dxa(npx-1,j))/(dxa(npx-1,j) + dxa(npx,j))
       enddo
       do j=js2, je1
          qout(npx,j) = edge_e(j)*q2(j-1) + (1.-edge_e(j))*q2(j)
       enddo
!
       do j=max(1,js-2),min(npy-1,je+2)
              g_in = dxa(npx-2,j) / dxa(npx-1,j)
              g_ou = dxa(npx+1,j) / dxa(npx,j)
          qx(npx,j) = 0.5*( ((2.+g_in)*qin(npx-1,j)-qin(npx-2,j))/(1.+g_in) +          &
                            ((2.+g_ou)*qin(npx,  j)-qin(npx+1,j))/(1.+g_ou) )
          qx(npx-1,j) = (3.*(qin(npx-2,j)+g_in*qin(npx-1,j)) - (g_in*qx(npx,j)+qx(npx-2,j)))/(2.+2.*g_in)
       enddo
    endif

    end if
!------------
! Y-Interior:
!------------

    if (gridstruct%bounded_domain) then


    do j=js,je+1
       do i=is-2,ie+2
          qy(i,j) = b2*(qin(i,j-2)+qin(i,j+1)) + b1*(qin(i,j-1) + qin(i,j))
       enddo
    enddo

    else

    do j=max(3,js),min(npy-2,je+1)
       do i=max(1,is-2), min(npx-1,ie+2)
          qy(i,j) = b2*(qin(i,j-2)+qin(i,j+1)) + b1*(qin(i,j-1) + qin(i,j))
       enddo
    enddo

    ! South Edges:
    if ( js==1 ) then
       do i=is1, ie1
          q1(i) = (qin(i,0)*dya(i,1) + qin(i,1)*dya(i,0))/(dya(i,0) + dya(i,1))
       enddo
       do i=is2, ie1
          qout(i,1) = edge_s(i)*q1(i-1) + (1.-edge_s(i))*q1(i)
       enddo
!
       do i=max(1,is-2),min(npx-1,ie+2)
             g_in = dya(i,2) / dya(i,1)
             g_ou = dya(i,-1) / dya(i,0)
          qy(i,1) = 0.5*( ((2.+g_in)*qin(i,1)-qin(i,2))/(1.+g_in) +          &
                          ((2.+g_ou)*qin(i,0)-qin(i,-1))/(1.+g_ou) )
          qy(i,2) = (3.*(g_in*qin(i,1)+qin(i,2)) - (g_in*qy(i,1)+qy(i,3)))/(2.+2.*g_in)
       enddo
    endif

    ! North Edges:
    if ( (je+1)==npy ) then
       do i=is1, ie1
          q1(i) = (qin(i,npy-1)*dya(i,npy) + qin(i,npy)*dya(i,npy-1))/(dya(i,npy-1)+dya(i,npy))
       enddo
       do i=is2, ie1
          qout(i,npy) = edge_n(i)*q1(i-1) + (1.-edge_n(i))*q1(i)
       enddo
!
       do i=max(1,is-2),min(npx-1,ie+2)
              g_in = dya(i,npy-2) / dya(i,npy-1)
              g_ou = dya(i,npy+1) / dya(i,npy)
          qy(i,npy) = 0.5*( ((2.+g_in)*qin(i,npy-1)-qin(i,npy-2))/(1.+g_in) +          &
                            ((2.+g_ou)*qin(i,npy  )-qin(i,npy+1))/(1.+g_ou) )
          qy(i,npy-1) = (3.*(qin(i,npy-2)+g_in*qin(i,npy-1)) - (g_in*qy(i,npy)+qy(i,npy-2)))/(2.+2.*g_in)
       enddo
    endif

    end if
!--------------------------------------

    if (gridstruct%bounded_domain) then

    do j=js, je+1
       do i=is,ie+1
          qxx(i,j) = a2*(qx(i,j-2)+qx(i,j+1)) + a1*(qx(i,j-1)+qx(i,j))
       enddo
    enddo

    do j=js,je+1
       do i=is,ie+1
          qyy(i,j) = a2*(qy(i-2,j)+qy(i+1,j)) + a1*(qy(i-1,j)+qy(i,j))
       enddo

       do i=is,ie+1
          qout(i,j) = 0.5*(qxx(i,j) + qyy(i,j))   ! averaging
       enddo
    enddo



    else

    do j=max(3,js),min(npy-2,je+1)
       do i=max(2,is),min(npx-1,ie+1)
          qxx(i,j) = a2*(qx(i,j-2)+qx(i,j+1)) + a1*(qx(i,j-1)+qx(i,j))
       enddo
    enddo

    if ( js==1 ) then
       do i=max(2,is),min(npx-1,ie+1)
          qxx(i,2) = c1*(qx(i,1)+qx(i,2))+c2*(qout(i,1)+qxx(i,3))
       enddo
    endif
    if ( (je+1)==npy ) then
       do i=max(2,is),min(npx-1,ie+1)
          qxx(i,npy-1) = c1*(qx(i,npy-2)+qx(i,npy-1))+c2*(qout(i,npy)+qxx(i,npy-2))
       enddo
    endif


    do j=max(2,js),min(npy-1,je+1)
       do i=max(3,is),min(npx-2,ie+1)
          qyy(i,j) = a2*(qy(i-2,j)+qy(i+1,j)) + a1*(qy(i-1,j)+qy(i,j))
       enddo
       if ( is==1 ) qyy(2,j) = c1*(qy(1,j)+qy(2,j))+c2*(qout(1,j)+qyy(3,j))
       if((ie+1)==npx) qyy(npx-1,j) = c1*(qy(npx-2,j)+qy(npx-1,j))+c2*(qout(npx,j)+qyy(npx-2,j))

       do i=max(2,is),min(npx-1,ie+1)
          qout(i,j) = 0.5*(qxx(i,j) + qyy(i,j))   ! averaging
       enddo
    enddo

    end if

 else  ! grid_type>=3
!------------------------
! Doubly periodic domain:
!------------------------
! X-sweep: PPM
    do j=js-2,je+2
       do i=is,ie+1
          qx(i,j) = b1*(qin(i-1,j)+qin(i,j)) + b2*(qin(i-2,j)+qin(i+1,j))
       enddo
    enddo
! Y-sweep: PPM
    do j=js,je+1
       do i=is-2,ie+2
          qy(i,j) = b1*(qin(i,j-1)+qin(i,j)) + b2*(qin(i,j-2)+qin(i,j+1))
       enddo
    enddo

    do j=js,je+1
       do i=is,ie+1
          qout(i,j) = 0.5*( a1*(qx(i,j-1)+qx(i,j  ) + qy(i-1,j)+qy(i,  j)) +  &
                            a2*(qx(i,j-2)+qx(i,j+1) + qy(i-2,j)+qy(i+1,j)) )
       enddo
    enddo
 endif

    if ( present(replace) ) then
       if ( replace ) then
          do j=js,je+1
          do i=is,ie+1
             qin(i,j) = qout(i,j)
          enddo
          enddo
       endif
    endif

  end subroutine a2b_ord4

  subroutine a2b_ord2(qin, qout, gridstruct, npx, npy, is, ie, js, je, ng, replace)
    integer, intent(IN   ) :: npx, npy, is, ie, js, je, ng
    real   , intent(INOUT) ::  qin(is-ng:ie+ng,js-ng:je+ng)   ! A-grid field
    real   , intent(  OUT) :: qout(is-ng:ie+ng,js-ng:je+ng)   ! Output  B-grid field
    type(fv_grid_type), intent(IN), target :: gridstruct
    logical, optional, intent(IN) ::  replace
    ! local:
    real q1(npx), q2(npy)
    integer :: i,j
    integer :: is1, js1, is2, js2, ie1, je1

    real, pointer, dimension(:,:,:) :: grid, agrid
    real, pointer, dimension(:,:)   :: dxa, dya

  real(kind=R_GRID), pointer, dimension(:) :: edge_w, edge_e, edge_s, edge_n

  edge_w => gridstruct%edge_w
  edge_e => gridstruct%edge_e
  edge_s => gridstruct%edge_s
  edge_n => gridstruct%edge_n

    grid => gridstruct%grid
    agrid => gridstruct%agrid
    dxa => gridstruct%dxa
    dya => gridstruct%dya

    if (gridstruct%grid_type < 3) then

       if (gridstruct%bounded_domain) then

          do j=js-2,je+1+2
             do i=is-2,ie+1+2
                qout(i,j) = 0.25*(qin(i-1,j-1)+qin(i,j-1)+qin(i-1,j)+qin(i,j))
             enddo
          enddo

       else

    is1 = max(1,is-1)
    js1 = max(1,js-1)
    is2 = max(2,is)
    js2 = max(2,js)

    ie1 = min(npx-1,ie+1)
    je1 = min(npy-1,je+1)

    do j=js2,je1
       do i=is2,ie1
          qout(i,j) = 0.25*(qin(i-1,j-1)+qin(i,j-1)+qin(i-1,j)+qin(i,j))
       enddo
    enddo

! Fix the 4 Corners:
    if ( gridstruct%sw_corner ) qout(1,    1) = r3*(qin(1,        1)+qin(1,      0)+qin(0,      1))
    if ( gridstruct%se_corner ) qout(npx,  1) = r3*(qin(npx-1,    1)+qin(npx-1,  0)+qin(npx,    1))
    if ( gridstruct%ne_corner ) qout(npx,npy) = r3*(qin(npx-1,npy-1)+qin(npx,npy-1)+qin(npx-1,npy))
    if ( gridstruct%nw_corner ) qout(1,  npy) = r3*(qin(1,    npy-1)+qin(0,  npy-1)+qin(1,    npy))

    ! *** West Edges:
    if ( is==1 ) then
       do j=js1, je1
          q2(j) = 0.5*(qin(0,j) + qin(1,j))
       enddo
       do j=js2, je1
          qout(1,j) = edge_w(j)*q2(j-1) + (1.-edge_w(j))*q2(j)
       enddo
    endif

    ! East Edges:
    if ( (ie+1)==npx ) then
       do j=js1, je1
          q2(j) = 0.5*(qin(npx-1,j) + qin(npx,j))
       enddo
       do j=js2, je1
          qout(npx,j) = edge_e(j)*q2(j-1) + (1.-edge_e(j))*q2(j)
       enddo
    endif

    ! South Edges:
    if ( js==1 ) then
       do i=is1, ie1
          q1(i) = 0.5*(qin(i,0) + qin(i,1))
       enddo
       do i=is2, ie1
          qout(i,1) = edge_s(i)*q1(i-1) + (1.-edge_s(i))*q1(i)
       enddo
    endif

    ! North Edges:
    if ( (je+1)==npy ) then
       do i=is1, ie1
          q1(i) = 0.5*(qin(i,npy-1) + qin(i,npy))
       enddo
       do i=is2, ie1
          qout(i,npy) = edge_n(i)*q1(i-1) + (1.-edge_n(i))*q1(i)
       enddo
    endif

 end if

 else

    do j=js,je+1
       do i=is,ie+1
          qout(i,j) = 0.25*(qin(i-1,j-1)+qin(i,j-1)+qin(i-1,j)+qin(i,j))
       enddo
    enddo

 endif


    if ( present(replace) ) then
       if ( replace ) then
          do j=js,je+1
             do i=is,ie+1
                qin(i,j) = qout(i,j)
             enddo
          enddo
       endif
    endif

  end subroutine a2b_ord2

  real function extrap_corner ( p0, p1, p2, q1, q2 )
    real, intent(in ), dimension(2):: p0, p1, p2
    real, intent(in ):: q1, q2
    real:: x1, x2

    x1 = great_circle_dist( real(p1,kind=R_GRID), real(p0,kind=R_GRID) )
    x2 = great_circle_dist( real(p2,kind=R_GRID), real(p0,kind=R_GRID) )

    extrap_corner = q1 + x1/(x2-x1) * (q1-q2)

  end function extrap_corner

end module a2b_edge_mod
