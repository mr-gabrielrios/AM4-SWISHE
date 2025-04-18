
                   module convection_utilities_mod

implicit none
private

public conv_tendency_type, mp2uwconv_type,   conv_output_type, &
       donner_input_type,  conv_results_type


!-------------version number ----------------------------------------

character(len=128)  :: version = '$Id$'
character(len=128)  :: tagname = '$Name$'


type conv_results_type

integer, dimension(:,:), allocatable    :: cldbot
integer, dimension(:,:), allocatable    :: cldtop
real,    dimension(:,:,:), allocatable  :: prod_no

real, dimension(:,:,:), allocatable     :: ras_mflux
real, dimension(:,:,:), allocatable     :: donner_mflux
real, dimension(:,:,:), allocatable     :: donner_mflux_up
real, dimension(:,:,:), allocatable     :: uw_mflux
real, dimension(:,:,:), allocatable     :: ras_det_mflux
real, dimension(:,:,:), allocatable     :: donner_det_mflux
real, dimension(:,:,:), allocatable     :: mc_donner
real, dimension(:,:,:), allocatable     :: mc_donner_half
real, dimension(:,:,:), allocatable     :: mc_donner_up  
logical, dimension(:,:  ), allocatable  :: conv_calc_completed
real   , dimension(:,:,:), allocatable  :: available_cf_for_uw

end type conv_results_type


type conv_tendency_type

      real, dimension(:,:,:)  , allocatable   :: ttnd
      real, dimension(:,:,:)  , allocatable   :: qtnd
      real, dimension(:,:,:)  , allocatable   :: utnd
      real, dimension(:,:,:)  , allocatable   :: vtnd
      real, dimension(:,:,:)  , allocatable   :: qltnd
      real, dimension(:,:,:)  , allocatable   :: qitnd
      real, dimension(:,:,:)  , allocatable   :: qatnd
      real, dimension(:,:,:)  , allocatable   :: qntnd
      real, dimension(:,:,:)  , allocatable   :: qnitnd
      real, dimension(:,:,:)  , allocatable   :: rain3d
      real, dimension(:,:,:)  , allocatable   :: snow3d
      real, dimension(:,:  )  , allocatable   :: rain
      real, dimension(:,:  )  , allocatable   :: snow  
      real, dimension(:,:,:)  , allocatable   :: delta_q
      real, dimension(:,:,:,:), allocatable   :: qtr 

end type conv_tendency_type


type mp2uwconv_type

      real, dimension (:,:),   allocatable   :: shflx 
      real, dimension (:,:),   allocatable   :: lhflx  
      real, dimension (:,:,:), allocatable   :: tdt_dif
      real, dimension (:,:,:), allocatable   :: qdt_dif

end type mp2uwconv_type

type conv_output_type

      real, dimension(:,:,:), allocatable    :: delta_temp
      real, dimension(:,:,:), allocatable    :: delta_vapor
      real, dimension(:,:,:), allocatable    :: delta_q
      real, dimension(:,:,:), allocatable    :: delta_qa
      real, dimension(:,:,:), allocatable    :: delta_ql
      real, dimension(:,:,:), allocatable    :: delta_qi
      real, dimension(:,:,:), allocatable    :: delta_qn
      real, dimension(:,:,:), allocatable    :: delta_qni
      real, dimension(:,:,:), allocatable    :: liquid_precip
      real, dimension(:,:,:), allocatable    :: frozen_precip
      real, dimension(:,:,:), allocatable    :: mc_donner
      real, dimension(:,:,:), allocatable    :: mc_donner_half
      real, dimension(:,:  ), allocatable    :: vert_motion
      real, dimension(:,:  ), allocatable    :: lheat_precip  
      real, dimension(:,:  ), allocatable    :: total_precip  
      real, dimension(:,:  ), allocatable    :: scale         
      real, dimension(:,:  ), allocatable    :: scale_REV
      real, dimension(:,:  ), allocatable    :: precip_adjustment
      real, dimension(:,:  ), allocatable    :: adjust_frac      
      real, dimension(:,:,:), allocatable    :: ttnd_adjustment
      real, dimension(:,:  ), allocatable    :: precip_returned  
      real, dimension(:,:,:,:), allocatable    :: donner_tracer    

end type   conv_output_type


type donner_input_type

      real, dimension(:,:,:), allocatable    :: rin
      real, dimension(:,:  ), allocatable    :: sfc_sh_flux
      real, dimension(:,:  ), allocatable    :: sfc_vapor_flux
      real, dimension(:,:,:), allocatable    :: tr_flux
      real, dimension(:,:  ), allocatable    :: ke_bl  
      integer, dimension(:,:  ), allocatable :: maxTe_launch_level
      real, dimension(:,:,:,:), allocatable  :: qtr
      real, dimension(:,:,:), allocatable    :: qlin
      real, dimension(:,:,:), allocatable    :: qiin
      real, dimension(:,:,:), allocatable    :: qain
      real, dimension(:,:,:), allocatable    :: nllin
      real, dimension(:,:,:), allocatable    :: nilin
      integer                                :: secs, days

end type donner_input_type



                            contains



                 end module convection_utilities_mod
