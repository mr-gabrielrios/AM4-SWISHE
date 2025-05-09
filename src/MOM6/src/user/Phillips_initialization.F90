module Phillips_initialization

! This file is part of MOM6. See LICENSE.md for the license.

use MOM_error_handler, only : MOM_mesg, MOM_error, FATAL, is_root_pe
use MOM_dyn_horgrid, only : dyn_horgrid_type
use MOM_file_parser, only : get_param, log_version, param_file_type
use MOM_get_input, only : directories
use MOM_grid, only : ocean_grid_type
use MOM_sponge, only : set_up_sponge_field, initialize_sponge, sponge_CS
use MOM_tracer_registry, only : tracer_registry_type
use MOM_variables, only : thermo_var_ptrs
use MOM_verticalGrid, only : verticalGrid_type
use MOM_EOS, only : calculate_density, calculate_density_derivs, EOS_type

implicit none ; private

#include <MOM_memory.h>

public Phillips_initialize_thickness
public Phillips_initialize_velocity
public Phillips_initialize_sponges
public Phillips_initialize_topography

! This include declares and sets the variable "version".
#include "version_variable.h"

contains

!> Initialize thickness field.
subroutine Phillips_initialize_thickness(h, G, GV, param_file, just_read_params)
  type(ocean_grid_type),   intent(in) :: G          !< The ocean's grid structure.
  type(verticalGrid_type), intent(in) :: GV         !< The ocean's vertical grid structure.
  real, dimension(SZI_(G),SZJ_(G),SZK_(GV)), &
                           intent(out) :: h         !< The thickness that is being initialized, in H.
  type(param_file_type),   intent(in)  :: param_file  !< A structure indicating the open file
                                                      !! to parse for model parameter values.
  logical,       optional, intent(in)  :: just_read_params !< If present and true, this call will
                                                      !! only read parameters without changing h.

  real :: eta0(SZK_(G)+1)   ! The 1-d nominal positions of the interfaces.
  real :: eta_im(SZJ_(G),SZK_(G)+1) ! A temporary array for zonal-mean eta, m.
  real :: eta1D(SZK_(G)+1)  ! Interface height relative to the sea surface
                            ! positive upward, in m.
  real :: damp_rate, jet_width, jet_height, y_2
  real :: half_strat, half_depth
  logical :: just_read    ! If true, just read parameters but set nothing.
  character(len=40)  :: mdl = "Phillips_initialize_thickness" ! This subroutine's name.
  integer :: i, j, k, is, ie, js, je, isd, ied, jsd, jed, nz

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed

  eta_im(:,:) = 0.0

  just_read = .false. ; if (present(just_read_params)) just_read = just_read_params

  if (.not.just_read) call log_version(param_file, mdl, version)
  call get_param(param_file, mdl, "HALF_STRAT_DEPTH", half_strat, &
                 "The maximum depth of the ocean.", units="nondim", &
                 default = 0.5, do_not_log=just_read)
  call get_param(param_file, mdl, "JET_WIDTH", jet_width, &
                 "The width of the zonal-mean jet.", units="km", &
                 fail_if_missing=.not.just_read, do_not_log=just_read)
  call get_param(param_file, mdl, "JET_HEIGHT", jet_height, &
                 "The interface height scale associated with the \n"//&
                 "zonal-mean jet.", units="m", &
                 fail_if_missing=.not.just_read, do_not_log=just_read)

  if (just_read) return ! All run-time parameters have been read, so return.

  half_depth = G%max_depth*half_strat
  eta0(1) = 0.0 ; eta0(nz+1) = -G%max_depth
  do k=2,1+nz/2 ; eta0(k) = -half_depth*(2.0*(k-1)/real(nz)) ; enddo
  do k=2+nz/2,nz+1
    eta0(k) = -G%max_depth - 2.0*(G%max_depth-half_depth) * ((k-(nz+1))/real(nz))
  enddo

  do j=js,je
    eta_im(j,1) = 0.0 ; eta_im(j,nz+1) = -G%max_depth
  enddo
  do K=2,nz ; do j=js,je
    y_2 = G%geoLatT(is,j) - G%south_lat - 0.5*G%len_lat
    eta_im(j,K) = eta0(k) + &
         jet_height * tanh(y_2 / jet_width)
!         jet_height * atan(y_2 / jet_width)
    if (eta_im(j,K) > 0.0) eta_im(j,K) = 0.0
    if (eta_im(j,K) < -G%max_depth) eta_im(j,K) = -G%max_depth
  enddo ; enddo

  do j=js,je ; do i=is,ie
!    This sets the initial thickness (in m) of the layers.  The      !
!  thicknesses are set to insure that: 1.  each layer is at least an !
!  Angstrom thick, and 2.  the interfaces are where they should be   !
!  based on the resting depths and interface height perturbations,   !
!  as long at this doesn't interfere with 1.                         !
    eta1D(nz+1) = -1.0*G%bathyT(i,j)
    do k=nz,1,-1
      eta1D(K) = eta_im(j,K)
      if (eta1D(K) < (eta1D(K+1) + GV%Angstrom_z)) then
        eta1D(K) = eta1D(K+1) + GV%Angstrom_z
        h(i,j,k) = GV%Angstrom
      else
        h(i,j,k) = GV%m_to_H * (eta1D(K) - eta1D(K+1))
      endif
    enddo
  enddo ; enddo

end subroutine Phillips_initialize_thickness

!> Initialize velocity fields.
subroutine Phillips_initialize_velocity(u, v, G, GV, param_file, just_read_params)
  type(ocean_grid_type),   intent(in)  :: G  !< Grid structure
  type(verticalGrid_type), intent(in)  :: GV !< Vertical grid structure
  real, dimension(SZIB_(G),SZJ_(G),SZK_(G)), &
                           intent(out) :: u  !< i-component of velocity [m/s]
  real, dimension(SZI_(G),SZJB_(G),SZK_(G)), &
                           intent(out) :: v  !< j-component of velocity [m/s]
  type(param_file_type),   intent(in)  :: param_file !< A structure indicating the open file to
                                                        !! parse for modelparameter values.
  logical,       optional, intent(in)  :: just_read_params !< If present and true, this call will
                                                      !! only read parameters without changing h.

  real :: damp_rate, jet_width, jet_height, x_2, y_2
  real :: velocity_amplitude, pi
  integer :: i, j, k, is, ie, js, je, nz, m
  logical :: just_read    ! If true, just read parameters but set nothing.
  character(len=40)  :: mdl = "Phillips_initialize_velocity" ! This subroutine's name.
  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke

  just_read = .false. ; if (present(just_read_params)) just_read = just_read_params

  if (.not.just_read) call log_version(param_file, mdl, version)
  call get_param(param_file, mdl, "VELOCITY_IC_PERTURB_AMP", velocity_amplitude, &
                 "The magnitude of the initial velocity perturbation.", &
                 units="m s-1", default=0.001, do_not_log=just_read)
  call get_param(param_file, mdl, "JET_WIDTH", jet_width, &
                 "The width of the zonal-mean jet.", units="km", &
                 fail_if_missing=.not.just_read, do_not_log=just_read)
  call get_param(param_file, mdl, "JET_HEIGHT", jet_height, &
                 "The interface height scale associated with the \n"//&
                 "zonal-mean jet.", units="m", &
                 fail_if_missing=.not.just_read, do_not_log=just_read)

  if (just_read) return ! All run-time parameters have been read, so return.

  u(:,:,:) = 0.0
  v(:,:,:) = 0.0

  pi = 4.0*atan(1.0)

  ! Use thermal wind shear to give a geostrophically balanced flow.
  do k=nz-1,1 ; do j=js,je ; do I=is-1,ie
    y_2 = G%geoLatCu(I,j) - G%south_lat - 0.5*G%len_lat
! This uses d/d y_2 atan(y_2 / jet_width)
!    u(I,j,k) = u(I,j,k+1) + (1e-3 * jet_height / &
!           (jet_width * (1.0 + (y_2 / jet_width)**2))) * &
!           (2.0 * GV%g_prime(K+1) / (G%CoriolisBu(I,J) + G%CoriolisBu(I,J-1)))
! This uses d/d y_2 tanh(y_2 / jet_width)
    u(I,j,k) = u(I,j,k+1) + (1e-3 * (jet_height / jet_width) * &
           (sech(y_2 / jet_width))**2 ) * &
           (2.0 * GV%g_prime(K+1) / (G%CoriolisBu(I,J) + G%CoriolisBu(I,J-1)))
  enddo ; enddo ; enddo

  do k=1,nz ; do j=js,je ; do I=is-1,ie
    y_2 = (G%geoLatCu(I,j) - G%south_lat - 0.5*G%len_lat) / G%len_lat
    x_2 = (G%geoLonCu(I,j) - G%west_lon - 0.5*G%len_lon) / G%len_lon
    if (G%geoLonCu(I,j) == G%west_lon) then
      ! This modification is required so that the perturbations are identical for
      ! symmetric and non-symmetric memory.  It is exactly equivalent to
      ! taking the longitude at the eastern edge of the domain, so that x_2 ~= 0.5.
      x_2 = ((G%west_lon + G%len_lon*REAL(G%ieg-(G%isg-1))/REAL(G%Domain%niglobal)) - &
             G%west_lon - 0.5*G%len_lon) / G%len_lon
    endif
    u(I,j,k) = u(I,j,k) + velocity_amplitude * ((real(k)-0.5)/real(nz)) * &
           (0.5 - abs(2.0*x_2) + 0.1*abs(cos(10.0*pi*x_2)) - abs(sin(5.0*pi*y_2)))
    do m=1,10
      u(I,j,k) = u(I,j,k) + 0.2*velocity_amplitude * ((real(k)-0.5)/real(nz)) * &
            cos(2.0*m*pi*x_2 + 2*m) * cos(6.0*pi*y_2)
    enddo
  enddo ; enddo ; enddo

end subroutine Phillips_initialize_velocity

!> Sets up the the inverse restoration time (Idamp), and
! the values towards which the interface heights and an arbitrary
! number of tracers should be restored within each sponge.
subroutine Phillips_initialize_sponges(G, use_temperature, tv, param_file, CSp, h)
  type(ocean_grid_type), intent(in) :: G    !< The ocean's grid structure.
  logical, intent(in) :: use_temperature    !< Switch for temperature.
  type(thermo_var_ptrs), intent(in) :: tv   !< A structure containing pointers
                                            !! to any available thermodynamic
                                            !! fields, potential temperature and
                                            !! salinity or mixed layer density.
                                            !! Absent fields have NULL ptrs.
  type(param_file_type), intent(in) :: param_file !< A structure indicating the
                                            !! open file to parse for model
                                            !! parameter values.
  type(sponge_CS),   pointer    :: CSp      !< A pointer that is set to point to
                                            !! the control structure for the
                                            !! sponge module.
  real, intent(in), dimension(SZI_(G),SZJ_(G), SZK_(G)) :: h !< Thickness field.

  real :: eta0(SZK_(G)+1)   ! The 1-d nominal positions of the interfaces.
  real :: eta(SZI_(G),SZJ_(G),SZK_(G)+1) ! A temporary array for eta, m.
  real :: temp(SZI_(G),SZJ_(G),SZK_(G))  ! A temporary array for other variables. !
  real :: Idamp(SZI_(G),SZJ_(G))    ! The inverse damping rate, in s-1.
  real :: eta_im(SZJ_(G),SZK_(G)+1) ! A temporary array for zonal-mean eta, m.
  real :: Idamp_im(SZJ_(G))         ! The inverse zonal-mean damping rate, in s-1.
  real :: damp_rate, jet_width, jet_height, y_2
  real :: half_strat, half_depth
  character(len=40)  :: mdl = "Phillips_initialize_sponges" ! This subroutine's name.

  integer :: i, j, k, is, ie, js, je, isd, ied, jsd, jed, nz
  logical, save :: first_call = .true.

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec ; nz = G%ke
  isd = G%isd ; ied = G%ied ; jsd = G%jsd ; jed = G%jed

  eta(:,:,:) = 0.0 ; temp(:,:,:) = 0.0 ; Idamp(:,:) = 0.0
  eta_im(:,:) = 0.0 ; Idamp_im(:) = 0.0

  if (first_call) call log_version(param_file, mdl, version)
  first_call = .false.
  call get_param(param_file, mdl, "HALF_STRAT_DEPTH", half_strat, &
                 "The maximum depth of the ocean.", units="nondim", &
                 default = 0.5)
  call get_param(param_file, mdl, "SPONGE_RATE", damp_rate, &
                 "The rate at which the zonal-mean sponges damp.", units="s-1", &
                 default = 1.0/(10.0*86400.0))

  call get_param(param_file, mdl, "JET_WIDTH", jet_width, &
                 "The width of the zonal-mean jet.", units="km", &
                 fail_if_missing=.true.)
  call get_param(param_file, mdl, "JET_HEIGHT", jet_height, &
                 "The interface height scale associated with the \n"//&
                 "zonal-mean jet.", units="m", &
                 fail_if_missing=.true.)

  half_depth = G%max_depth*half_strat
  eta0(1) = 0.0 ; eta0(nz+1) = -G%max_depth
  do k=2,1+nz/2 ; eta0(k) = -half_depth*(2.0*(k-1)/real(nz)) ; enddo
  do k=2+nz/2,nz+1
    eta0(k) = -G%max_depth - 2.0*(G%max_depth-half_depth) * ((k-(nz+1))/real(nz))
  enddo

  do j=js,je
    Idamp_im(j) = damp_rate
    eta_im(j,1) = 0.0 ; eta_im(j,nz+1) = -G%max_depth
  enddo
  do K=2,nz ; do j=js,je
    y_2 = G%geoLatT(is,j) - G%south_lat - 0.5*G%len_lat
    eta_im(j,K) = eta0(k) + &
         jet_height * tanh(y_2 / jet_width)
!         jet_height * atan(y_2 / jet_width)
    if (eta_im(j,K) > 0.0) eta_im(j,K) = 0.0
    if (eta_im(j,K) < -G%max_depth) eta_im(j,K) = -G%max_depth
  enddo ; enddo

  call initialize_sponge(Idamp, eta, G, param_file, CSp, Idamp_im, eta_im)

end subroutine Phillips_initialize_sponges

!> sech calculates the hyperbolic secant.
function sech(x)
  real, intent(in) :: x    !< Input value.
  real             :: sech !< Result.

  ! This is here to prevent overflows or underflows.
  if (abs(x) > 228.) then
    sech = 0.0
  else
    sech = 2.0 / (exp(x) + exp(-x))
  endif
end function sech

!> Initialize topography.
subroutine Phillips_initialize_topography(D, G, param_file, max_depth)
  type(dyn_horgrid_type),             intent(in)  :: G !< The dynamic horizontal grid type
  real, dimension(G%isd:G%ied,G%jsd:G%jed), &
                                      intent(out) :: D !< Ocean bottom depth in m
  type(param_file_type),              intent(in)  :: param_file !< Parameter file structure
  real,                               intent(in)  :: max_depth  !< Maximum depth of model in m

  real :: PI, Htop, Wtop, Ltop, offset, dist, &
          x1, x2, x3, x4, y1, y2
  integer :: i,j,is,ie,js,je
  character(len=40)  :: mdl = "Phillips_initialize_topography" ! This subroutine's name.

  is = G%isc ; ie = G%iec ; js = G%jsc ; je = G%jec

  PI = 4.0*atan(1.0)

  call get_param(param_file, mdl, "PHILLIPS_HTOP", Htop,             &
                 "The maximum height of the topography.", units="m", &
                 fail_if_missing=.true.)
! Htop=0.375*G%max_depth     ! max height of topog. above max_depth
  Wtop=0.5*G%len_lat       ! meridional width of drake and mount
  Ltop=0.25*G%len_lon      ! zonal width of topographic features
  offset=0.1*G%len_lat ! meridional offset from center
  dist=0.333*G%len_lon       ! distance between drake and mount
                           ! should be longer than Ltop/2

  y1=G%south_lat+0.5*G%len_lat+offset-0.5*Wtop; y2=y1+Wtop
  x1=G%west_lon+0.1*G%len_lon; x2=x1+Ltop; x3=x1+dist; x4=x3+3.0/2.0*Ltop

  do i=is,ie ; do j=js,je
     D(i,j)=0.0
     if (G%geoLonT(i,j)>x1 .and. G%geoLonT(i,j)<x2) then
       D(i,j) = Htop*sin(PI*(G%geoLonT(i,j)-x1)/(x2-x1))**2
       if (G%geoLatT(i,j)>y1 .and. G%geoLatT(i,j)<y2) then
          D(i,j)=D(i,j)*(1-sin(PI*(G%geoLatT(i,j)-y1)/(y2-y1))**2)
       end if
     else if (G%geoLonT(i,j)>x3 .and. G%geoLonT(i,j)<x4 .and. &
              G%geoLatT(i,j)>y1 .and. G%geoLatT(i,j)<y2) then
       D(i,j) = 2.0/3.0*Htop*sin(PI*(G%geoLonT(i,j)-x3)/(x4-x3))**2 &
                    *sin(PI*(G%geoLatT(i,j)-y1)/(y2-y1))**2
     end if
     D(i,j)=max_depth-D(i,j)
  enddo; enddo

end subroutine Phillips_initialize_topography

!> \namespace phillips_initialization
!!
!!  By Robert Hallberg, April 1994 - June 2002                         *
!!                                                                     *
!!    This subroutine initializes the fields for the simulations.      *
!!  The one argument passed to initialize, Time, is set to the         *
!!  current time of the simulation.  The fields which are initialized  *
!!  here are:                                                          *
!!    u - Zonal velocity in m s-1.                                     *
!!    v - Meridional velocity in m s-1.                                *
!!    h - Layer thickness in m.  (Must be positive.)                   *
!!    D - Basin depth in m.  (Must be positive.)                       *
!!    f - The Coriolis parameter, in s-1.                              *
!!    g - The reduced gravity at each interface, in m s-2.             *
!!    Rlay - Layer potential density (coordinate variable) in kg m-3.  *
!!  If ENABLE_THERMODYNAMICS is defined:                               *
!!    T - Temperature in C.                                            *
!!    S - Salinity in psu.                                             *
!!  If SPONGE is defined:                                              *
!!    A series of subroutine calls are made to set up the damping      *
!!    rates and reference profiles for all variables that are damped   *
!!    in the sponge.                                                   *
!!  Any user provided tracer code is also first linked through this    *
!!  subroutine.                                                        *
!!                                                                     *
!!    Forcing-related fields (taux, tauy, buoy, ustar, etc.) are set   *
!!  in MOM_surface_forcing.F90.                                        *
!!                                                                     *
!!    These variables are all set in the set of subroutines (in this   *
!!  file) Phillips_initialize_thickness, Phillips_initialize_velocity, *
!!  Phillips_initialize_topography and Phillips_initialize_sponges     *
!!  that seet up fields that are specific to the Phillips instability  *
!!  test case.                                                         *
!!                                                                     *
!!  Macros written all in capital letters are defined in MOM_memory.h. *
!!                                                                     *
!!     A small fragment of the grid is shown below:                    *
!!                                                                     *
!!    j+1  x ^ x ^ x   At x:  q, f                                     *
!!    j+1  > o > o >   At ^:  v, tauy                                  *
!!    j    x ^ x ^ x   At >:  u, taux                                  *
!!    j    > o > o >   At o:  h, D, buoy, tr, T, S, ustar              *
!!    j-1  x ^ x ^ x                                                   *
!!        i-1  i  i+1  At x & ^:                                       *
!!           i  i+1    At > & o:                                       *
!!                                                                     *
!!  The boundaries always run through q grid points (x).               *
end module Phillips_initialization
