module MOM_horizontal_regridding
! This file is part of MOM6. See LICENSE.md for the license.

use MOM_debugging, only : hchksum
use MOM_coms, only : max_across_PEs, min_across_PEs
use MOM_cpu_clock, only : cpu_clock_id, cpu_clock_begin, cpu_clock_end
use MOM_cpu_clock, only :  CLOCK_ROUTINE, CLOCK_LOOP
use MOM_domains, only : pass_var, pass_vector, sum_across_PEs, broadcast
use MOM_domains, only : root_PE, To_All, SCALAR_PAIR, CGRID_NE, AGRID
use MOM_error_handler, only : MOM_mesg, MOM_error, FATAL, WARNING, is_root_pe
use MOM_error_handler, only : callTree_enter, callTree_leave, callTree_waypoint
use MOM_file_parser, only : get_param, read_param, log_param, param_file_type
use MOM_file_parser, only : log_version
use MOM_get_input, only : directories
use MOM_grid, only : ocean_grid_type, isPointInCell
use MOM_io, only : close_file, fieldtype, file_exists
use MOM_io, only : open_file, read_data, read_axis_data, SINGLE_FILE, MULTIPLE
use MOM_io, only : slasher, vardesc, write_field
use MOM_string_functions, only : uppercase
use MOM_time_manager, only : time_type, set_time, get_external_field_size
use MOM_time_manager, only : init_external_field, time_interp_external
use MOM_time_manager, only : get_external_field_axes, get_external_field_missing
use MOM_variables, only : thermo_var_ptrs
use mpp_io_mod, only : axistype
use mpp_domains_mod, only  : mpp_global_field, mpp_get_compute_domain
use mpp_mod, only          : mpp_broadcast,mpp_root_pe,mpp_sync,mpp_sync_self
use mpp_mod, only          : mpp_max
use horiz_interp_mod, only : horiz_interp_new, horiz_interp,horiz_interp_type
use horiz_interp_mod, only : horiz_interp_init, horiz_interp_del

use mpp_io_mod, only : mpp_get_axis_data
use mpp_io_mod, only : MPP_SINGLE
use netcdf

implicit none ; private

#include <MOM_memory.h>

public :: horiz_interp_and_extrap_tracer, myStats

character(len=40)  :: mdl = "MOM_horizontal_regridding" ! This module's name.

interface fill_boundaries
  module procedure fill_boundaries_real
  module procedure fill_boundaries_int
end interface

interface horiz_interp_and_extrap_tracer
   module procedure horiz_interp_and_extrap_tracer_record
   module procedure horiz_interp_and_extrap_tracer_fms_id
end interface

real, parameter :: epsln=1.e-10

contains


subroutine myStats(array, missing, is, ie, js, je, k, mesg)
  real, dimension(:,:), intent(in) :: array
  real, intent(in) :: missing
  integer :: is,ie,js,je,k
  character(len=*) :: mesg
  ! Local variables
  real :: minA, maxA
  integer :: i,j
  logical :: found
  character(len=120) :: lMesg
  minA = 9.E24 ; maxA = -9.E24 ; found = .false.

  do j = js, je
     do i = is, ie
        if (array(i,j) /= array(i,j)) stop 'Nan!'
        if (abs(array(i,j)-missing)>1.e-6*abs(missing)) then
           if (found) then
              minA = min(minA, array(i,j))
              maxA = max(maxA, array(i,j))
           else
              found = .true.
              minA = array(i,j)
              maxA = array(i,j)
           endif
        endif
     enddo
  enddo
  call min_across_PEs(minA)
  call max_across_PEs(maxA)
  if (is_root_pe()) then
     write(lMesg(1:120),'(2(a,es12.4),a,i3,x,a)') &
          'init_from_Z: min=',minA,' max=',maxA,' Level=',k,trim(mesg)
     call MOM_mesg(lMesg,2)
  endif
end subroutine myStats

subroutine fill_miss_2d(aout,good,fill,prev,G,smooth,num_pass,relc,crit,keep_bug,debug)
  !
  !# Use ICE-9 algorithm to populate points (fill=1) with
  !# valid data (good=1). If no information is available,
  !# Then use a previous guess (prev). Optionally (smooth)
  !# blend the filled points to achieve a more desirable result.
  !
  !  (in)        a   : input 2-d array with missing values
  !  (in)     good   : valid data mask for incoming array (1==good data; 0==missing data)
  !  (in)     fill   : same shape array of points which need filling (1==please fill;0==leave it alone)
  !  (in)     prev   : first guess where isolated holes exist,
  !
  use MOM_coms, only : sum_across_PEs

  type(ocean_grid_type),            intent(inout) :: G    !< The ocean's grid structure.
  real, dimension(SZI_(G),SZJ_(G)), intent(inout) :: aout
  real, dimension(SZI_(G),SZJ_(G)), intent(in)    :: good !< Valid data mask for incoming array
                                                          !! (1==good data; 0==missing data).
  real, dimension(SZI_(G),SZJ_(G)), intent(in)    :: fill !< Same shape array of points which need
                                                          !! filling (1==please fill;0==leave
                                                          !! it alone).
  real, dimension(SZI_(G),SZJ_(G)), optional, &
                                    intent(in)    :: prev !< First guess where isolated holes exist.
  logical, intent(in),              optional      :: smooth
  integer, intent(in),              optional      :: num_pass
  real,                 intent(in), optional      :: relc,crit
  logical,              intent(in), optional      :: keep_bug, debug


  real, dimension(SZI_(G),SZJ_(G)) :: b,r
  real, dimension(SZI_(G),SZJ_(G)) :: fill_pts,good_,good_new

  integer :: i,j,k
  real    :: east,west,north,south,sor
  real    :: ge,gw,gn,gs,ngood
  logical :: do_smooth,siena_bug
  real    :: nfill, nfill_prev
  integer, parameter :: num_pass_default = 10000
  real, parameter :: relc_default = 0.25, crit_default = 1.e-3

  integer :: npass
  integer :: is, ie, js, je
  real    :: relax_coeff, acrit, ares
  logical :: debug_it

  debug_it=.false.
  if (PRESENT(debug)) debug_it=debug

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec

  npass = num_pass_default
  if (PRESENT(num_pass)) npass = num_pass

  relax_coeff = relc_default
  if (PRESENT(relc)) relax_coeff = relc

  acrit = crit_default
  if (PRESENT(crit)) acrit = crit

  siena_bug=.false.
  if (PRESENT(keep_bug)) siena_bug = keep_bug

  do_smooth=.false.
  if (PRESENT(smooth)) do_smooth=smooth

  fill_pts(:,:)=fill(:,:)

  nfill = sum(fill(is:ie,js:je))
  call sum_across_PEs(nfill)

  nfill_prev = nfill
  good_(:,:)=good(:,:)
  r(:,:)=0.0

  do while (nfill > 0.0)

     call pass_var(good_,G%Domain)
     call pass_var(aout,G%Domain)

     b(:,:)=aout(:,:)
     good_new(:,:)=good_(:,:)

     do j=js,je
        i_loop: do i=is,ie

           if (good_(i,j) .eq. 1.0 .or. fill(i,j) .eq. 0.) cycle i_loop

           ge=good_(i+1,j);gw=good_(i-1,j)
           gn=good_(i,j+1);gs=good_(i,j-1)
           east=0.0;west=0.0;north=0.0;south=0.0
           if (ge.eq.1.0) east=aout(i+1,j)*ge
           if (gw.eq.1.0) west=aout(i-1,j)*gw
           if (gn.eq.1.0) north=aout(i,j+1)*gn
           if (gs.eq.1.0) south=aout(i,j-1)*gs

           ngood = ge+gw+gn+gs
           if (ngood > 0.) then
              b(i,j)=(east+west+north+south)/ngood
              fill_pts(i,j)=0.0
              good_new(i,j)=1.0
           endif
        enddo i_loop
     enddo

     aout(is:ie,js:je)=b(is:ie,js:je)
     good_(is:ie,js:je)=good_new(is:ie,js:je)
     nfill_prev = nfill
     nfill = sum(fill_pts(is:ie,js:je))
     call sum_across_PEs(nfill)

     if (nfill == nfill_prev .and. PRESENT(prev)) then
        do j=js,je
           do i=is,ie
              if (fill_pts(i,j).eq.1.0) then
                 aout(i,j)=prev(i,j)
                 fill_pts(i,j)=0.0
              endif
           enddo
        enddo
     else if (nfill .eq. nfill_prev) then
        print *,&
             'Unable to fill missing points using either data at the same vertical level from a connected basin'//&
             'or using a point from a previous vertical level.  Make sure that the original data has some valid'//&
             'data in all basins.'
        print *,'nfill=',nfill
     endif

     nfill = sum(fill_pts(is:ie,js:je))
     call sum_across_PEs(nfill)

  end do

  if (do_smooth) then
     do k=1,npass
        call pass_var(aout,G%Domain)
        do j=js,je
           do i=is,ie
              if (fill(i,j) .eq. 1) then
                 east=max(good(i+1,j),fill(i+1,j));west=max(good(i-1,j),fill(i-1,j))
                 north=max(good(i,j+1),fill(i,j+1));south=max(good(i,j-1),fill(i,j-1))
                 r(i,j) = relax_coeff*(south*aout(i,j-1)+north*aout(i,j+1)+west*aout(i-1,j)+east*aout(i+1,j) - (south+north+west+east)*aout(i,j))
              else
                 r(i,j) = 0.
              endif
           enddo
        enddo
        aout(is:ie,js:je)=r(is:ie,js:je)+aout(is:ie,js:je)
        ares = maxval(abs(r))
        call max_across_PEs(ares)
        if (ares <= acrit) exit
     enddo
  endif

  do j=js,je
     do i=is,ie
        if (good_(i,j).eq.0.0 .and. fill_pts(i,j) .eq. 1.0) then
           print *,'in fill_miss, fill, good,i,j= ',fill_pts(i,j),good_(i,j),i,j
           call MOM_error(FATAL,"MOM_initialize: "// &
                "fill is true and good is false after fill_miss, how did this happen? ")
        endif
     enddo
  enddo

  return

end subroutine fill_miss_2d

subroutine horiz_interp_and_extrap_tracer_record(filename, varnam,  conversion, recnum, G, tr_z, mask_z, z_in, &
                                                z_edges_in, missing_value, reentrant_x, tripolar_n, homogenize )

  character(len=*),      intent(in)    :: filename   !< Path to file containing tracer to be
                                                     !! interpolated.
  character(len=*),      intent(in)    :: varnam     !< Name of tracer in filee.
  real,                  intent(in)    :: conversion !< Conversion factor for tracer.
  integer,               intent(in)    :: recnum     !< Record number of tracer to be read.
  type(ocean_grid_type), intent(inout) :: G          !< Grid object
  real, allocatable, dimension(:,:,:)  :: tr_z       !< pointer to allocatable tracer array on local
                                                     !! model grid and native vertical levels.
  real, allocatable, dimension(:,:,:)  :: mask_z     !< pointer to allocatable tracer mask array on
                                                     !! local model grid and native vertical levels.
  real, allocatable,     dimension(:)  :: z_in       !< Cell grid values for input data.
  real, allocatable,     dimension(:)  :: z_edges_in !< Cell grid edge values for input data.
  real,                  intent(out)   :: missing_value
  logical,               intent(in)    :: reentrant_x, tripolar_n
  logical, intent(in),   optional      :: homogenize

  real, dimension(:,:),  allocatable   :: tr_in,tr_inp !< A 2-d array for holding input data on
                                                     !! native horizontal grid and extended grid
                                                     !! with poles.
  real, dimension(:,:),  allocatable   :: mask_in    !< A 2-d mask for extended input grid.

  real :: PI_180
  integer :: rcode, ncid, varid, ndims, id, jd, kd, jdp
  integer :: i,j,k
  integer, dimension(4) :: start, count, dims, dim_id
  real, dimension(:,:), allocatable :: x_in, y_in
  real, dimension(:), allocatable  :: lon_in, lat_in
  real, dimension(:), allocatable  :: lat_inp, last_row
  real :: max_lat, min_lat, pole, max_depth, npole
  real :: roundoff  ! The magnitude of roundoff, usually ~2e-16.
  logical :: add_np
  character(len=8)  :: laynum
  type(horiz_interp_type) :: Interp
  integer :: is, ie, js, je     ! compute domain indices
  integer :: isc,iec,jsc,jec    ! global compute domain indices
  integer :: isg, ieg, jsg, jeg ! global extent
  integer :: isd, ied, jsd, jed ! data domain indices
  integer :: id_clock_read
  character(len=12)  :: dim_name(4)
  logical :: debug=.false.
  real :: npoints,varAvg
  real, dimension(SZI_(G),SZJ_(G)) :: lon_out, lat_out, tr_out, mask_out
  real, dimension(SZI_(G),SZJ_(G)) :: good, fill
  real, dimension(SZI_(G),SZJ_(G)) :: tr_outf,tr_prev
  real, dimension(SZI_(G),SZJ_(G))  :: good2,fill2
  real, dimension(SZI_(G),SZJ_(G))  :: nlevs

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  isg = G%isg ; ieg = G%ieg ; jsg = G%jsg ; jeg = G%jeg

  id_clock_read = cpu_clock_id('(Initialize tracer from Z) read', grain=CLOCK_LOOP)


  if (ALLOCATED(tr_z)) deallocate(tr_z)
  if (ALLOCATED(mask_z)) deallocate(mask_z)
  if (ALLOCATED(z_edges_in)) deallocate(z_edges_in)

  PI_180=atan(1.0)/45.

  ! Open NetCDF file and if present, extract data and spatial coordinate information
  ! The convention adopted here requires that the data be written in (i,j,k) ordering.

  call cpu_clock_begin(id_clock_read)


  rcode = NF90_OPEN(filename, NF90_NOWRITE, ncid)
  if (rcode .ne. 0) call MOM_error(FATAL,"error opening file "//trim(filename)//&
                           " in hinterp_extrap")
  rcode = NF90_INQ_VARID(ncid, varnam, varid)
  if (rcode .ne. 0) call MOM_error(FATAL,"error finding variable "//trim(varnam)//&
                                 " in file "//trim(filename)//" in hinterp_extrap")

  rcode = NF90_INQUIRE_VARIABLE(ncid, varid, ndims=ndims, dimids=dims)
  if (rcode .ne. 0) call MOM_error(FATAL,'error inquiring dimensions hinterp_extrap')
  if (ndims < 3) call MOM_error(FATAL,"Variable "//trim(varnam)//" in file "// &
              trim(filename)//" has too few dimensions.")

  rcode = NF90_INQUIRE_DIMENSION(ncid, dims(1), dim_name(1), len=id)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 1 data for "// &
                trim(varnam)//" in file "// trim(filename)//" in hinterp_extrap")
  rcode = NF90_INQ_VARID(ncid, dim_name(1), dim_id(1))
  if (rcode .ne. 0) call MOM_error(FATAL,"error finding variable "//trim(dim_name(1))//&
                                 " in file "//trim(filename)//" in hinterp_extrap")
  rcode = NF90_INQUIRE_DIMENSION(ncid, dims(2), dim_name(2), len=jd)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 2 data for "// &
                trim(varnam)//" in file "// trim(filename)//" in hinterp_extrap")
  rcode = NF90_INQ_VARID(ncid, dim_name(2), dim_id(2))
  if (rcode .ne. 0) call MOM_error(FATAL,"error finding variable "//trim(dim_name(2))//&
                                 " in file "//trim(filename)//" in hinterp_extrap")
  rcode = NF90_INQUIRE_DIMENSION(ncid, dims(3), dim_name(3), len=kd)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 3 data for "// &
                trim(varnam)//" in file "// trim(filename)//" in hinterp_extrap")
  rcode = NF90_INQ_VARID(ncid, dim_name(3), dim_id(3))
  if (rcode .ne. 0) call MOM_error(FATAL,"error finding variable "//trim(dim_name(3))//&
                                 " in file "//trim(filename)//" in hinterp_extrap")


  missing_value=0.0
  rcode = NF90_GET_ATT(ncid, varid, "_FillValue", missing_value)
  if (rcode .ne. 0) call MOM_error(FATAL,"error finding missing value for "//&
       trim(varnam)//" in file "// trim(filename)//" in hinterp_extrap")

  if (allocated(lon_in)) deallocate(lon_in)
  if (allocated(lat_in)) deallocate(lat_in)
  if (allocated(z_in)) deallocate(z_in)
  if (allocated(z_edges_in)) deallocate(z_edges_in)
  if (allocated(tr_z)) deallocate(tr_z)
  if (allocated(mask_z)) deallocate(mask_z)


  allocate(lon_in(id),lat_in(jd),z_in(kd),z_edges_in(kd+1))
  allocate(tr_z(isd:ied,jsd:jed,kd), mask_z(isd:ied,jsd:jed,kd))

  start = 1; count = 1; count(1) = id
  rcode = NF90_GET_VAR(ncid, dim_id(1), lon_in, start, count)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 1 values for var_name "// &
                trim(varnam)//",dim_name "//trim(dim_name(1))//" in file "// trim(filename)//" in hinterp_extrap")
  start = 1; count = 1; count(1) = jd
  rcode = NF90_GET_VAR(ncid, dim_id(2), lat_in, start, count)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 2 values for var_name "// &
                trim(varnam)//",dim_name "//trim(dim_name(2))//" in file "// trim(filename)//" in  hinterp_extrap")
  start = 1; count = 1; count(1) = kd
  rcode = NF90_GET_VAR(ncid, dim_id(3), z_in, start, count)
  if (rcode .ne. 0) call MOM_error(FATAL,"error reading dimension 3 values for var_name "// &
                trim(varnam//",dim_name "//trim(dim_name(3)))//" in file "// trim(filename)//" in  hinterp_extrap")

  call cpu_clock_end(id_clock_read)

! extrapolate the input data to the north pole using the northerm-most latitude

  max_lat = maxval(lat_in)
  add_np=.false.
  if (max_lat < 90.0) then
    add_np=.true.
    jdp=jd+1
    allocate(lat_inp(jdp))
    lat_inp(1:jd)=lat_in(:)
    lat_inp(jd+1)=90.0
    deallocate(lat_in)
    allocate(lat_in(1:jdp))
    lat_in(:)=lat_inp(:)
  else
    jdp=jd
  endif

! construct level cell boundaries as the mid-point between adjacent centers

  z_edges_in(1) = 0.0
  do k=2,kd
   z_edges_in(k)=0.5*(z_in(k-1)+z_in(k))
  enddo
  z_edges_in(kd+1)=2.0*z_in(kd) - z_in(kd-1)

  call horiz_interp_init()

  lon_in = lon_in*PI_180
  lat_in = lat_in*PI_180
  allocate(x_in(id,jdp),y_in(id,jdp))
  call meshgrid(lon_in,lat_in, x_in, y_in)

  lon_out(:,:) = G%geoLonT(:,:)*PI_180
  lat_out(:,:) = G%geoLatT(:,:)*PI_180


  allocate(tr_in(id,jd)) ; tr_in(:,:)=0.0
  allocate(tr_inp(id,jdp)) ; tr_inp(:,:)=0.0
  allocate(mask_in(id,jdp)) ; mask_in(:,:)=0.0
  allocate(last_row(id))    ; last_row(:)=0.0

  max_depth = maxval(G%bathyT)
  call mpp_max(max_depth)

  if (z_edges_in(kd+1)<max_depth) z_edges_in(kd+1)=max_depth


! loop through each data level and interpolate to model grid.
! after interpolating, fill in points which will be needed
! to define the layers

  roundoff = 3.0*EPSILON(missing_value)


  do k=1,kd
    write(laynum,'(I8)') k ; laynum = adjustl(laynum)

    if (is_root_pe()) then
      start = 1; start(3) = k; count = 1; count(1) = id; count(2) = jd
      rcode = NF90_GET_VAR(ncid,varid, tr_in, start, count)
      if (rcode .ne. 0) call MOM_error(FATAL,"hinterp_and_extract_from_Fie: "//&
           "error reading level "//trim(laynum)//" of variable "//&
           trim(varnam)//" in file "// trim(filename))

      if (add_np) then
         last_row(:)=tr_in(:,jd); pole=0.0;npole=0.0
         do i=1,id
            if (abs(tr_in(i,jd)-missing_value) .gt. abs(roundoff*missing_value)) then
               pole = pole+last_row(i)
               npole = npole+1.0
            endif
         enddo
         if (npole > 0) then
            pole=pole/npole
         else
            pole=missing_value
         endif
         tr_inp(:,1:jd) = tr_in(:,:)
         tr_inp(:,jdp) = pole
      else
         tr_inp(:,:) = tr_in(:,:)
      endif

    endif

    call mpp_sync()
    call mpp_broadcast(tr_inp,id*jdp,root_PE())
    call mpp_sync_self ()

    mask_in=0.0

    do j=1,jdp
      do i=1,id
         if (abs(tr_inp(i,j)-missing_value) .gt. abs(roundoff*missing_value)) then
           mask_in(i,j)=1.0
            tr_inp(i,j) = tr_inp(i,j) * conversion
         else
           tr_inp(i,j)=missing_value
         endif
      enddo
    enddo


! call fms routine horiz_interp to interpolate input level data to model horizontal grid


    if (k == 1) then
      call horiz_interp_new(Interp,x_in,y_in,lon_out(is:ie,js:je),lat_out(is:ie,js:je), &
               interp_method='bilinear',src_modulo=reentrant_x)
    endif

    if (debug) then
       call myStats(tr_inp,missing_value, is,ie,js,je,k,'Tracer from file')
    endif

    tr_out(:,:) = 0.0

    call horiz_interp(Interp,tr_inp,tr_out(is:ie,js:je), missing_value=missing_value, new_missing_handle=.true.)

    mask_out=1.0
    do j=js,je
      do i=is,ie
        if (abs(tr_out(i,j)-missing_value) .lt. abs(roundoff*missing_value)) mask_out(i,j)=0.
      enddo
    enddo

    fill = 0.0; good = 0.0

    nPoints = 0 ; varAvg = 0.
    do j=js,je
      do i=is,ie
        if (mask_out(i,j) .lt. 1.0) then
          tr_out(i,j)=missing_value
        else
          good(i,j)=1.0
          nPoints = nPoints + 1
          varAvg = varAvg + tr_out(i,j)
        endif
        if (G%mask2dT(i,j) == 1.0 .and. z_edges_in(k) <= G%bathyT(i,j) .and. mask_out(i,j) .lt. 1.0) fill(i,j)=1.0
      enddo
    enddo
    call pass_var(fill,G%Domain)
    call pass_var(good,G%Domain)

    if (debug) then
      call myStats(tr_out,missing_value, is,ie,js,je,k,'variable from horiz_interp()')
    endif

    ! Horizontally homogenize data to produce perfectly "flat" initial conditions
    if (PRESENT(homogenize)) then
       if (homogenize) then
          call sum_across_PEs(nPoints)
          call sum_across_PEs(varAvg)
          if (nPoints>0) then
             varAvg = varAvg/real(nPoints)
          endif
          tr_out(:,:) = varAvg
       endif
    endif

! tr_out contains input z-space data on the model grid with missing values
! now fill in missing values using "ICE-nine" algorithm.

    tr_outf(:,:)=tr_out(:,:)
    if (k==1) tr_prev(:,:)=tr_outf(:,:)
    good2(:,:)=good(:,:)
    fill2(:,:)=fill(:,:)

    call fill_miss_2d(tr_outf,good2,fill2,tr_prev,G,smooth=.true.)
    call myStats(tr_outf,missing_value,is,ie,js,je,k,'field from fill_miss_2d()')

    tr_z(:,:,k) = tr_outf(:,:)*G%mask2dT(:,:)
    mask_z(:,:,k) = good2(:,:)+fill2(:,:)

    tr_prev(:,:)=tr_z(:,:,k)

    if (debug) then
      call hchksum(tr_prev,'field after fill ',G%HI)
    endif

  enddo ! kd

end subroutine horiz_interp_and_extrap_tracer_record

subroutine horiz_interp_and_extrap_tracer_fms_id(fms_id,  Time, conversion, G, tr_z, mask_z, z_in, &
                                                z_edges_in, missing_value, reentrant_x, tripolar_n, homogenize )

  integer,               intent(in)    :: fms_id     !< A unique id used by the FMS time interpolator
  type(time_type),       intent(in)    :: Time       !< A FMS time type
  real,                  intent(in)    :: conversion !< Conversion factor for tracer.
  type(ocean_grid_type), intent(inout) :: G          !< Grid object
  real, allocatable, dimension(:,:,:)  :: tr_z       !< pointer to allocatable tracer array on local
                                                     !! model grid and native vertical levels.
  real, allocatable, dimension(:,:,:)  :: mask_z     !< pointer to allocatable tracer mask array on
                                                     !! local model grid and native vertical levels.
  real, allocatable,     dimension(:)  :: z_in       !< Cell grid values for input data.
  real, allocatable,     dimension(:)  :: z_edges_in !< Cell grid edge values for input data.
  real,                  intent(out)   :: missing_value
  logical,               intent(in)    :: reentrant_x, tripolar_n
  logical, intent(in),   optional      :: homogenize

  real, dimension(:,:),  allocatable   :: tr_in,tr_inp !< A 2-d array for holding input data on
                                                     !! native horizontal grid and extended grid
                                                     !! with poles.
  real, dimension(:,:,:), allocatable  :: data_in    !< A buffer for storing the full 3-d time-interpolated array
                                                     !! on the original grid
  real, dimension(:,:),  allocatable   :: mask_in    !< A 2-d mask for extended input grid.

  real :: PI_180
  integer :: rcode, ncid, varid, ndims, id, jd, kd, jdp
  integer :: i,j,k
  integer, dimension(4) :: start, count, dims, dim_id
  real, dimension(:,:), allocatable :: x_in, y_in
  real, dimension(:), allocatable  :: lon_in, lat_in
  real, dimension(:), allocatable  :: lat_inp, last_row
  real :: max_lat, min_lat, pole, max_depth, npole
  real :: roundoff  ! The magnitude of roundoff, usually ~2e-16.
  logical :: add_np
  character(len=8)  :: laynum
  type(horiz_interp_type) :: Interp
  type(axistype), dimension(4) :: axes_data
  integer :: is, ie, js, je     ! compute domain indices
  integer :: isc,iec,jsc,jec    ! global compute domain indices
  integer :: isg, ieg, jsg, jeg ! global extent
  integer :: isd, ied, jsd, jed ! data domain indices
  integer :: id_clock_read
  integer, dimension(4) :: fld_sz
  character(len=12)  :: dim_name(4)
  logical :: debug=.false.
  real :: npoints,varAvg
  real, dimension(SZI_(G),SZJ_(G)) :: lon_out, lat_out, tr_out, mask_out
  real, dimension(SZI_(G),SZJ_(G)) :: good, fill
  real, dimension(SZI_(G),SZJ_(G)) :: tr_outf,tr_prev
  real, dimension(SZI_(G),SZJ_(G))  :: good2,fill2
  real, dimension(SZI_(G),SZJ_(G))  :: nlevs

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed
  isg = G%isg ; ieg = G%ieg ; jsg = G%jsg ; jeg = G%jeg

  id_clock_read = cpu_clock_id('(Initialize tracer from Z) read', grain=CLOCK_LOOP)


  PI_180=atan(1.0)/45.

  ! Open NetCDF file and if present, extract data and spatial coordinate information
  ! The convention adopted here requires that the data be written in (i,j,k) ordering.

  call cpu_clock_begin(id_clock_read)

  fld_sz = get_external_field_size(fms_id)

  if (allocated(lon_in)) deallocate(lon_in)
  if (allocated(lat_in)) deallocate(lat_in)
  if (allocated(z_in)) deallocate(z_in)
  if (allocated(z_edges_in)) deallocate(z_edges_in)
  if (allocated(tr_z)) deallocate(tr_z)
  if (allocated(mask_z)) deallocate(mask_z)

  axes_data =  get_external_field_axes(fms_id)

  id = fld_sz(1) ; jd  = fld_sz(2) ; kd = fld_sz(3)
  allocate(lon_in(id),lat_in(jd),z_in(kd),z_edges_in(kd+1))
  allocate(tr_z(isd:ied,jsd:jed,kd), mask_z(isd:ied,jsd:jed,kd))

  call mpp_get_axis_data(axes_data(1), lon_in)
  call mpp_get_axis_data(axes_data(2), lat_in)
  call mpp_get_axis_data(axes_data(3), z_in)

  call cpu_clock_end(id_clock_read)

  missing_value=get_external_field_missing(fms_id)


! extrapolate the input data to the north pole using the northerm-most latitude

  max_lat = maxval(lat_in)
  add_np=.false.
  if (max_lat < 90.0) then
    add_np=.true.
    jdp=jd+1
    allocate(lat_inp(jdp))
    lat_inp(1:jd)=lat_in(:)
    lat_inp(jd+1)=90.0
    deallocate(lat_in)
    allocate(lat_in(1:jdp))
    lat_in(:)=lat_inp(:)
  else
    jdp=jd
  endif

! construct level cell boundaries as the mid-point between adjacent centers

  z_edges_in(1) = 0.0
  do k=2,kd
   z_edges_in(k)=0.5*(z_in(k-1)+z_in(k))
  enddo
  z_edges_in(kd+1)=2.0*z_in(kd) - z_in(kd-1)

  call horiz_interp_init()

  lon_in = lon_in*PI_180
  lat_in = lat_in*PI_180
  allocate(x_in(id,jdp),y_in(id,jdp))
  call meshgrid(lon_in,lat_in, x_in, y_in)

  lon_out(:,:) = G%geoLonT(:,:)*PI_180
  lat_out(:,:) = G%geoLatT(:,:)*PI_180

  allocate(data_in(id,jd,kd)) ; data_in(:,:,:)=0.0
  allocate(tr_in(id,jd)) ; tr_in(:,:)=0.0
  allocate(tr_inp(id,jdp)) ; tr_inp(:,:)=0.0
  allocate(mask_in(id,jdp)) ; mask_in(:,:)=0.0
  allocate(last_row(id))    ; last_row(:)=0.0

  max_depth = maxval(G%bathyT)
  call mpp_max(max_depth)

  if (z_edges_in(kd+1)<max_depth) z_edges_in(kd+1)=max_depth

  if (is_root_pe()) &
  call time_interp_external(fms_id, Time, data_in,verbose=.true.)

! loop through each data level and interpolate to model grid.
! after interpolating, fill in points which will be needed
! to define the layers

!  roundoff = 3.0*EPSILON(missing_value)
  roundoff = 1.e-4

  do k=1,kd
    write(laynum,'(I8)') k ; laynum = adjustl(laynum)

    if (is_root_pe()) then
      tr_in(1:id,1:jd) = data_in(1:id,1:jd,k)
      if (add_np) then
         last_row(:)=tr_in(:,jd); pole=0.0;npole=0.0
         do i=1,id
            if (abs(tr_in(i,jd)-missing_value) .gt. abs(roundoff*missing_value)) then
               pole = pole+last_row(i)
               npole = npole+1.0
            endif
         enddo
         if (npole > 0) then
            pole=pole/npole
         else
            pole=missing_value
         endif
         tr_inp(:,1:jd) = tr_in(:,:)
         tr_inp(:,jdp) = pole
      else
         tr_inp(:,:) = tr_in(:,:)
      endif

    endif

    call mpp_sync()
    call mpp_broadcast(tr_inp,id*jdp,root_PE())
    call mpp_sync_self ()

    mask_in=0.0

    do j=1,jdp
      do i=1,id
         if (abs(tr_inp(i,j)-missing_value) .gt. abs(roundoff*missing_value)) then
           mask_in(i,j)=1.0
           tr_inp(i,j) = tr_inp(i,j) * conversion
         else
           tr_inp(i,j)=missing_value
         endif
      enddo
    enddo


! call fms routine horiz_interp to interpolate input level data to model horizontal grid


    if (k == 1) then
      call horiz_interp_new(Interp,x_in,y_in,lon_out(is:ie,js:je),lat_out(is:ie,js:je), &
               interp_method='bilinear',src_modulo=reentrant_x)
    endif

!    if (debug) then
       call myStats(tr_in,missing_value, 1,id,1,jd,k,'Tracer from file')
!    endif

    tr_out(:,:) = 0.0

    call horiz_interp(Interp,tr_inp,tr_out(is:ie,js:je), missing_value=missing_value, new_missing_handle=.true.)

    mask_out=1.0
    do j=js,je
      do i=is,ie
        if (abs(tr_out(i,j)-missing_value) .lt. abs(roundoff*missing_value)) mask_out(i,j)=0.
      enddo
    enddo

    fill = 0.0; good = 0.0

    nPoints = 0 ; varAvg = 0.
    do j=js,je
      do i=is,ie
        if (mask_out(i,j) .lt. 1.0) then
          tr_out(i,j)=missing_value
        else
          good(i,j)=1.0
          nPoints = nPoints + 1
          varAvg = varAvg + tr_out(i,j)
        endif
        if (G%mask2dT(i,j) == 1.0 .and. z_edges_in(k) <= G%bathyT(i,j) .and. mask_out(i,j) .lt. 1.0) fill(i,j)=1.0
      enddo
    enddo
    call pass_var(fill,G%Domain)
    call pass_var(good,G%Domain)

    if (debug) then
      call myStats(tr_out,missing_value, is,ie,js,je,k,'variable from horiz_interp()')
    endif

    ! Horizontally homogenize data to produce perfectly "flat" initial conditions
    if (PRESENT(homogenize)) then
       if (homogenize) then
          call sum_across_PEs(nPoints)
          call sum_across_PEs(varAvg)
          if (nPoints>0) then
             varAvg = varAvg/real(nPoints)
          endif
          tr_out(:,:) = varAvg
       endif
    endif

! tr_out contains input z-space data on the model grid with missing values
! now fill in missing values using "ICE-nine" algorithm.

    tr_outf(:,:)=tr_out(:,:)
    if (k==1) tr_prev(:,:)=tr_outf(:,:)
    good2(:,:)=good(:,:)
    fill2(:,:)=fill(:,:)

    call fill_miss_2d(tr_outf,good2,fill2,tr_prev,G,smooth=.true.)

!    if (debug) then
!      call hchksum(tr_outf,'field from fill_miss_2d ',G%HI)
!    endif

!    call myStats(tr_outf,missing_value,is,ie,js,je,k,'field from fill_miss_2d()')

    tr_z(:,:,k) = tr_outf(:,:)*G%mask2dT(:,:)
    mask_z(:,:,k) = good2(:,:)+fill2(:,:)
    tr_prev(:,:)=tr_z(:,:,k)

    if (debug) then
      call hchksum(tr_prev,'field after fill ',G%HI)
    endif

  enddo ! kd

end subroutine horiz_interp_and_extrap_tracer_fms_id
subroutine meshgrid(x,y,x_T,y_T)

!<  create a 2d-mesh of grid coordinates
!! from 1-d arrays.

real, dimension(:),                   intent(in)    :: x,y
real, dimension(size(x,1),size(y,1)), intent(inout) :: x_T,y_T

integer :: ni,nj,i,j

ni=size(x,1);nj=size(y,1)

do j=1,nj
  x_T(:,j)=x(:)
enddo

do i=1,ni
  y_T(i,:)=y(:)
enddo

return

end subroutine meshgrid
function fill_boundaries_int(m,cyclic_x,tripolar_n) result(mp)
!
! fill grid edges
!
integer, dimension(:,:), intent(in)             :: m
logical,                 intent(in)             :: cyclic_x, tripolar_n
real,    dimension(size(m,1),size(m,2))         :: m_real
real,    dimension(0:size(m,1)+1,0:size(m,2)+1) :: mp_real
integer, dimension(0:size(m,1)+1,0:size(m,2)+1) :: mp

m_real = real(m)

mp_real = fill_boundaries_real(m_real,cyclic_x,tripolar_n)

mp = int(mp_real)

return

end function fill_boundaries_int

function fill_boundaries_real(m,cyclic_x,tripolar_n) result(mp)
!< fill grid edges

real, dimension(:,:),             intent(in) :: m
logical,                          intent(in) :: cyclic_x, tripolar_n
real, dimension(0:size(m,1)+1,0:size(m,2)+1) :: mp

integer :: ni,nj,i,j

ni=size(m,1); nj=size(m,2)

mp(1:ni,1:nj)=m(:,:)

if (cyclic_x) then
  mp(0,1:nj)=m(ni,1:nj)
  mp(ni+1,1:nj)=m(1,1:nj)
else
  mp(0,1:nj)=m(1,1:nj)
  mp(ni+1,1:nj)=m(ni,1:nj)
endif

mp(1:ni,0)=m(1:ni,1)
if (tripolar_n) then
  do i=1,ni
    mp(i,nj+1)=m(ni-i+1,nj)
  enddo
else
  mp(1:ni,nj+1)=m(1:ni,nj)
endif

return

end function fill_boundaries_real

subroutine smooth_heights(zi,fill,bad,sor,niter,cyclic_x, tripolar_n)
!< Solve del2 (zi) = 0 using successive iterations
!! with a 5 point stencil. Only points fill==1 are
!! modified. Except where bad==1, information propagates
!! isotropically in index space.  The resulting solution
!! in each region is an approximation to del2(zi)=0 subject to
!! boundary conditions along the valid points curve bounding this region.

real,    dimension(:,:),                   intent(inout) :: zi
integer, dimension(size(zi,1),size(zi,2)), intent(in) :: fill
integer, dimension(size(zi,1),size(zi,2)), intent(in) :: bad
real,                                      intent(in)  :: sor
integer,                                   intent(in) :: niter
logical,                                   intent(in) :: cyclic_x, tripolar_n

integer :: i,j,k,n
integer :: ni,nj

real, dimension(size(zi,1),size(zi,2)) :: res, m
integer, dimension(size(zi,1),size(zi,2),4) :: B
real, dimension(0:size(zi,1)+1,0:size(zi,2)+1) :: mp
integer, dimension(0:size(zi,1)+1,0:size(zi,2)+1) :: nm

real :: Isum, bsum

ni=size(zi,1); nj=size(zi,2)


mp=fill_boundaries(zi,cyclic_x,tripolar_n)

B(:,:,:)=0.0
nm=fill_boundaries(bad,cyclic_x,tripolar_n)

do j=1,nj
  do i=1,ni
    if (fill(i,j) .eq. 1) then
      B(i,j,1)=1-nm(i+1,j);B(i,j,2)=1-nm(i-1,j)
      B(i,j,3)=1-nm(i,j+1);B(i,j,4)=1-nm(i,j-1)
    endif
  enddo
enddo

do n=1,niter
  do j=1,nj
    do i=1,ni
      if (fill(i,j) .eq. 1) then
        bsum = real(B(i,j,1)+B(i,j,2)+B(i,j,3)+B(i,j,4))
        Isum = 1.0/bsum
        res(i,j)=Isum*(B(i,j,1)*mp(i+1,j)+B(i,j,2)*mp(i-1,j)+&
             B(i,j,3)*mp(i,j+1)+B(i,j,4)*mp(i,j-1)) - mp(i,j)
      endif
    enddo
  enddo
  res(:,:)=res(:,:)*sor

  do j=1,nj
    do i=1,ni
      mp(i,j)=mp(i,j)+res(i,j)
    enddo
  enddo

  zi(:,:)=mp(1:ni,1:nj)
  mp = fill_boundaries(zi,cyclic_x,tripolar_n)
end do



return

end subroutine smooth_heights


end module MOM_horizontal_regridding
