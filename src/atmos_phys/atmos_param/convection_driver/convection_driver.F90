
                    module convection_driver_mod

!-----------------------------------------------------------------------
!
!         This module accesses the following convective parameterizations.
!         Access is controlled by logical variables found in 
!         moist_processes_nml.
!
!         ---------------------------------------
!         1)  dry convective adjustment
!         2)  moist convective adjustment
!         3)  relaxed arakawa-schubert
!         4)  donner deep convection
!         5)  betts-miller convective adjustment (3 varieties)
!         6)  uw convection
!
!         The following convective implementations are available:
!         -------------------------------------------------
!         1)  dry convective adjustment alone
!         2)  moist convective adjustment alone
!         3)  dry convective adjustment followed by moist convective 
!                                                               adjustment
!         4)  betts-miller convection alone, as either 
!                a) standard version,
!                b) a mass flux based version, or
!                c) a version developed by O. Pauluis.
!         5)  relaxed arakawa-schubert alone
!         6)  donner convection alone
!         7)  uw convection  alone
!         8)  donner convection followed by relaxed arakawa-schubert 
!         9)  donner convection followed by uw convection
!        10)  uw convection followed by donner convection
!             
!------------------------------------------------------------------------
!
!       The module also calculates cumulus momentum transport (if desired,
!    using either a diffusive or a non-local scheme), and produces needed
!    fields for input to the large-scale cloud scheme and COSP, updates 
!    the time tendencies of model variables as a result of convection, and
!    outputs convective diagnostics.
!    
!-----------------------------------------------------------------------



! infrastructure modules
use sat_vapor_pres_mod,     only: compute_qs
use time_manager_mod,       only: time_type, get_time, assignment(=)
use diag_manager_mod,       only: register_diag_field, send_data, &
                                  get_diag_field_id, DIAG_FIELD_NOT_FOUND
use diag_data_mod,          only: CMOR_MISSING_VALUE
use mpp_domains_mod,        only: domain2D
use mpp_mod,                only: input_nml_file
use fms2_io_mod,            only: file_exists
use fms_mod,                only: error_mesg, FATAL, WARNING,NOTE,&
                                  check_nml_error,    &
                                  write_version_number,           &
                                  mpp_pe, mpp_root_pe, stdlog,    &
                                  mpp_clock_id, mpp_clock_begin,  &
                                  mpp_clock_end, CLOCK_MODULE,    &
                                  CLOCK_MODULE_DRIVER, &
                                  MPP_CLOCK_SYNC
use field_manager_mod,      only: MODEL_ATMOS
use tracer_manager_mod,     only: get_tracer_index,&
                                  get_tracer_names, &
                                  NO_TRACER
use constants_mod,          only: CP_AIR, HLV, HLS, HLF, RDGAS, RVGAS, &
                                  SECONDS_PER_DAY, KAPPA, AVOGNO
use atmos_global_diag_mod,  only: register_global_diag_field, &
                                  buffer_global_diag
use atmos_cmip_diag_mod,    only: register_cmip_diag_field_2d, &
                                  register_cmip_diag_field_3d, &
                                  send_cmip_data_3d, &
                                  query_cmip_diag_id, &
                                  cmip_diag_id_type

! atmos modules
use physics_types_mod,      only: physics_control_type, phys_mp_exch_type
use vert_diff_driver_mod,   only: surf_diff_type
use physics_radiation_exch_mod,        &
                            only: clouds_from_moist_block_type, &
                                  exchange_control_type,  &
                                  cloud_scheme_data_type
use betts_miller_mod,       only: betts_miller, betts_miller_init
use bm_massflux_mod,        only: bm_massflux, bm_massflux_init
use bm_omp_mod,             only: bm_omp, bm_omp_init
use donner_deep_mod,        only: donner_deep_init,               &
                                  donner_deep_time_vary,  &
                                  donner_deep_endts,         &
                                  donner_deep, donner_deep_end,   &
                                  donner_deep_restart
use moist_conv_mod,         only: moist_conv, moist_conv_init
use uw_conv_mod,            only: uw_conv, uw_conv_end, uw_conv_init
use ras_mod,                only: ras_end, ras_init, ras
use dry_adj_mod,            only: dry_adj, dry_adj_init
use detr_ice_num_mod,       only: detr_ice_num, detr_ice_num_init,   &
                                  detr_ice_num_end
use rh_clouds_mod,          only: do_rh_clouds, rh_clouds_sum
use cu_mo_trans_mod,        only: cu_mo_trans_init, cu_mo_trans,   &
                                  cu_mo_trans_end
use moz_hook_mod,           only: moz_hook
use aerosol_types_mod,      only: aerosol_type
use moist_proc_utils_mod,   only: capecalcnew, column_diag, rh_calc, &
                                  mp_nml_type, mp_input_type,   &
                                  mp_tendency_type, mp_removal_type, &
                                  mp_removal_control_type, &
                                  mp_conv2ls_type, mp_output_type
use convection_utilities_mod,         &
                            only: conv_tendency_type,                 &
                                  conv_output_type, donner_input_type,&
                                  conv_results_type
use atmos_tracer_utilities_mod,         &
                            only: wet_deposition

implicit none
private

!-----------------------------------------------------------------------
!-------------------- public data/interfaces ---------------------------

public     convection_driver_init, convection_driver_time_vary,   &
           convection_driver, convection_driver_endts,  & 
           convection_driver_end,    &
           convection_driver_restart, cape_cin_diagnostics
  
private                             &
!   initialization:
           diag_field_init,    &
!   called in prognostic loop:
           convection_driver_alloc, define_total_convective_output,     &
           convective_diagnostics,  define_convective_area, &
           compute_convective_area,  & 
           define_inputs_for_cosp, prevent_neg_precip_fluxes, &
           convection_driver_dealloc, &
!   associated with donner convection:
           donner_driver, donner_alloc, donner_prep,   &
           process_donner_output, check_donner_conservation, &
           prevent_unrealizable_water, define_output_fields,  &
           donner_mca_driver, output_donner_diagnostics,  &
           donner_dealloc, &
!   associated with dry convective adjustment:
           dca_driver,     &
!   associated with betts-miller convection:
           betts_miller_driver,  &
!   associated with moist convective adjustment:
           mca_driver,  &
!   associated with uw-then-donner convection:
           uw_then_donner_driver, &
!   associated with uw convection:
           uw_conv_driver, uw_conv_driver_part,  uw_alloc,  &
           finalize_uw_outputs, update_inputs, uw_diagnostics, &
           uw_dealloc, &
!   associated with relaxed arakawa-schubert convection:
           ras_driver,   &
!   routines accessed by multiple convection implementations:
           update_outputs, define_and_apply_scale

!-----------------------------------------------------------------------
!-------------------- private data -------------------------------------

!--------------------- version number ----------------------------------
character(len=128) ::  version = '$Id: $'
character(len=128) :: tagname = '$Name: $'


!-------------------- namelist data (private) --------------------------

!---------------- namelist variable definitions -----------------------

!
!   do_cmt     = compute cumulus momentum transport (default = T).
!   cmt_mass_flux_source = parameterization(s) being used to supply the 
!                mass flux profiles seen by the cumulus momentum transport
!                module; currently either 'ras', 'donner', 'uw', 
!                'donner_and_ras', 'donner_and_uw', 'ras_and_uw', 
!                'donner_and_ras_and_uw' or 'all' (default = 'all').
 
!   do_gust_cv = switch to use convective gustiness (default = F).
!   do_gust_cv_new = switch to use newer convective gustiness expression   
!                                                    (default = F).
!   gustmax    = maximum convective gustiness (m/s); default = 3.
!   gustconst  = precip rate which defines precip rate which begins to
!                matter for convective gustiness (kg/m2/sec)
!                default = 1. cm/day = 10. mm/da

!   do_limit_donner = limit Donner deep tendencies to prevent the
!                formation of grid points with negative water vapor,
!                liquid or ice (default = T).
!
!   do_limit_uw = limit UW shallow tendencies to prevent the formation
!                of grid points with negative total water specific 
!                humidities. This situation can occur because both
!                shallow and deep convection operate on the same
!                soundings without knowledge of what the other is doing
!                (default = T).
!
!   do_unified_convective_closure = use cloud base mass flux calculated
!                in uw_conv module as value for donner deep parameter-
!                ization; adjust cbmf available for uw shallow appropr-
!                iately. only available when uw shallow and donner deep
!                are the active convective schemes, CURRENTLY IS NOT
!                AVAILABLE (default = F).

!   do_donner_before_uw =  calculate convection seen by donner scheme
!                before calculating what is seen by uw (default = T).
!   use_updated_profiles_for_uw = when donner convection is calculated 
!                first, update the profiles with its effects before 
!                calculating the uw convection (default = F).
!   use_updated_profiles_for_donner = when uw convection is calculated 
!                first, update the profiles with its effects before 
!                calculating the donner convection (default = F).
!   only_one_conv_scheme_per_column = once convection has been predicted 
!                in a column, do not allow another scheme to also compute
!                convection in that column (default = F).

!   force_donner_moist_conserv = adjust donner precip to exactly balance 
!                the moisture change in each model column (default = F).
!   do_donner_conservation_checks = Perform various checks to verify the
!                conservation of enthalpy and moisture as a result of the
!                donner convection calculation (default = T).

!   do_donner_mca = include a call to moist convective adjustment as a
!                final step in the donner calculation to remove any
!                remaining instability (default = F).

!   detrain_liq_num = if true, convective droplets may be detrained into
!                the large-scale clouds (default =  F).
!   detrain_ice_num = if true, convective ice particles may be detrained
!                into the large-scale clouds (default = F).

!   conv_frac_max = the largest allowable convective cloud fraction in a
!                grid box (default = 0.99, used only for clubb scheme).

!   remain_detrain_bug = setting this to T will result in retaining a bug
!                which resulted in 10x fewer liquid droplets being 
!                detrained into the large-scale clouds than should have 
!                been (default = F). 
!   keep_icenum_detrain_bug = setting this to T will result in retaining
!                a bug where the ice number detrainment calculation module
!                receives an inconsistent temperature field with which to
!                perform the calculation, whereas in the
!                corrected code, all fields are updated before uw 
!                convection is calculated.  (default = F).
!   reproduce_AM4 = setting this to T will reproduce legacy 
!                (warsaw) results because the model will use temperature 
!                and tracer fields that have not been updated with the uw 
!                convective tendency for the calculation of cu_mo_trans 
!                and lightning (updated values should have been used for 
!                consistency). ANSWERS THUS WILL CHANGE from warsaw results
!                for any runs using both uw convection and cu_mo_trans (or
!                tracer "no") when this variable is set to F, since in that
!                case all fields are updated with uw tendencies before the 
!                cumulus momentum transport and lightning calculations 
!                are done. (default = F).
!----------------------------------------------------------------------

logical            :: do_cmt=.true.
character(len=64)  :: cmt_mass_flux_source = 'all'
logical            :: do_gust_cv = .false.
logical            :: do_gust_cv_new = .false.
real               :: gustmax = 3.     
real               :: gustconst = 10./SECONDS_PER_DAY 
logical            :: do_limit_donner =.true. 
logical            :: do_limit_uw = .true.    
logical            :: do_unified_convective_closure = .false.
logical            :: do_donner_before_uw = .true.
logical            :: use_updated_profiles_for_uw = .false.
logical            :: use_updated_profiles_for_donner = .false.
logical            :: only_one_conv_scheme_per_column = .false.
logical            :: force_donner_moist_conserv = .false.
logical            :: do_donner_conservation_checks = .true.
logical            :: do_donner_mca=.false.
logical            :: detrain_liq_num = .false.
logical            :: detrain_ice_num = .false.
real               :: conv_frac_max = 0.99
logical            :: remain_detrain_bug = .false.
logical            :: keep_icenum_detrain_bug = .false.
logical            :: reproduce_AM4 = .true.


namelist /convection_driver_nml/    &
              do_cmt, cmt_mass_flux_source,   &
              do_gust_cv,  do_gust_cv_new, gustmax, gustconst, &
              do_limit_donner, do_limit_uw, &
              do_unified_convective_closure, &
              do_donner_before_uw,  use_updated_profiles_for_uw,  &
              use_updated_profiles_for_donner,  &
              only_one_conv_scheme_per_column,   &
              force_donner_moist_conserv, do_donner_conservation_checks, &
              do_donner_mca,     &
              detrain_liq_num, detrain_ice_num, &
              conv_frac_max,   &
              remain_detrain_bug, keep_icenum_detrain_bug, &
              reproduce_AM4


!------------------- other global variables  ------------------------


!  variables imported during initialization and saved as module variables:
real    :: qmin                    ! minimum value for condensate specific
                                   ! humidity
logical :: do_liq_num              ! prognostic cloud droplet number ?
logical :: do_ice_num              ! prognostic ice particle number ?
logical :: do_cosp                 ! call COSP diagnostic package ?
integer :: do_clubb                ! using CLUBB as the large-scale cloud 
                                   !                               scheme ?
logical :: do_lsc                  ! using bulk large scale condensation ?
logical :: do_mca                  ! moist convective adjustment is active?
logical :: do_ras                  ! relaxed arakawa-schubert param 
                                   !                             is active?
logical :: do_uw_conv              ! uw convection scheme is active ?
logical :: do_donner_deep          ! donner convection scheme is active ?
logical :: do_dryadj               ! dry convective adjustment is active ?
logical :: limit_conv_cloud_frac   ! total convective cloud area in a box 
                                   ! is limited to 0.999, when donner and 
                                   ! uw schemes are both active ?
logical :: include_donmca_in_cosp  ! assuming mca is included inside of 
                                   ! the donner scheme, are its contri-
                                   ! butions to be seen by COSP ?
logical :: do_rh_clouds_BM         ! are rh clouds to be included in the
                                   ! Betts-Miller scheme ? 
logical :: do_bm                   ! the basic bm scheme is active ?
logical :: do_bmmass               ! the mass flux version of bm 
                                   ! is active ?
logical :: do_bmomp                ! the Pauluis version of bm is active ?
logical :: do_simple               ! a simple formulation for rh is to be 
                                   ! used with the betts-miller scheme ?
integer :: num_donner_tracers, &   ! number of tracers transported by the
                                   ! donner scheme
           num_mca_tracers,    &   ! number of tracers to be transported
                                   ! by moist convective adjustment
           num_ras_tracers,   &    ! number of tracers to be transported 
                                   ! by the ras scheme
           num_uw_tracers          ! number of tracers to be transported 
                                   ! by the uw scheme
logical :: doing_prog_clouds       ! prognostic clouds are active ?
integer :: nsphum,   &             ! tracer index for specific humidity
           nql,      &             ! tracer index for cloud water
           nqi,      &             ! tracer index for cloud ice
           nqa,      &             ! tracer index for cloud area
           nqn,      &             ! tracer index for cloud droplet number
           nqni,     &             ! tracer index for cloud ice particle
                                   !                                number
           nqr,      &             ! tracer index for rain water
           nqs,      &             ! tracer index for snow
           nqg                     ! tracer index for graupel
integer :: num_prog_tracers        ! total number of prognostic tracers
logical, dimension(:), allocatable ::   &
           cloud_tracer            ! logical array indicating which tracers
                                   ! are cloud tracers 
logical, dimension(:), allocatable ::   &
           tracers_in_donner,   &  ! logical array indicating which tracers
                                   ! are transported by donner convection
           tracers_in_ras,&        ! logical array indicating which tracers
                                   ! are transported by ras convection
           tracers_in_uw,  &       ! logical array indicating which tracers
                                   ! are transported by uw convection
           tracers_in_mca          ! logical array indicating which tracers
                                   ! are transported by mca

!  variables imported during  the time_vary code segment and saved 
!  as module variables:
real    :: dt                      ! model timestep [s]
real    :: dtinv                   ! inverse of model timestep
type(time_type) :: Time            ! Time at end of current step, used for
                                   ! diagnostics
integer :: i_cell,     &           ! index of donner cell clouds in cloud
                                   ! array
           i_meso,     &           ! index of donner meso clouds in cloud
                                   ! array
           i_shallow               ! index of uw clouds in cloud array

!  variables used to define the active convective implementation: 
logical :: ldca = .false.          ! dry convective adjustment only
logical :: lmca = .false.          ! moist convective adjustment only
logical :: lras = .false.          ! ras only
logical :: luwconv = .false.       ! uw only
logical :: ldonner = .false.       ! donner only
logical :: lBM = .false.           ! Betts-Miller only
logical :: lBMmass = .false.       ! Betts-Miller mass version only
logical :: lBMomp = .false.        ! Betts-Miller Pauluis version only
logical :: ldcamca = .false.       ! dry, then moist cnvctve adjustment
logical :: ldonnerras = .false.    ! donner and ras
logical :: luw_then_donner = .false. 
                                   ! uw and then donner
logical :: ldonner_then_uw = .false.   
                                   ! donner first, then uw

real, allocatable, dimension(:,:)   ::  &
       max_enthalpy_imbal_don,   & ! max enthalpy budget imbalance from
                                   ! donner parameterization during 
                                   ! current job segment
       max_water_imbal_don         ! max h2o budget imbalance from
                                   ! donner parameterization during 
                                   ! current job segment


!-------------------- clock definitions --------------------------------

integer :: convection_clock,  &    ! clock to time total convection 
           donner_clock,      &    ! clock to time donner paramaeterization
           dca_clock,    &         ! clock to time dry conv adjustment
           mca_clock,    &         ! clock to time moist conv adjustment
           uw_clock,     &         ! clock to time uw parameterization
           donner_mca_clock,  &    ! clock to time mca with donner param
           bm_clock,    &          ! clock to time betts-miller param
           cmt_clock,   &          ! clock to time cumulus momentum
                                   !                  transport calculation
           ras_clock               ! clock to time ras parameterization

!-------------------- diagnostics variables ----------------------------

!CMIP diagnostics:
integer, public          :: id_pr_g, id_prc_g, id_prsn_g, id_prsnc, id_prrc
integer                  :: id_prc, id_ci, id_ccb, id_cct
type(cmip_diag_id_type)  :: ID_tntc, ID_tnhusc, ID_mc, ID_emilnox_area

!donner convection diagnostics
integer :: id_cell_cld_frac,  id_meso_cld_frac, id_donner_humidity_area, &
           id_mc_donner, id_mc_donner_half, &
           id_tdt_deep_donner, id_qdt_deep_donner, &
           id_qadt_deep_donner, id_qldt_deep_donner, id_qidt_deep_donner, &
           id_qndt_deep_donner,  id_qnidt_deep_donner, &
           id_tdt_mca_donner, id_qdt_mca_donner, &
           id_prec_deep_donner, id_precret_deep_donner,id_prec_mca_donner,&
           id_prec1_deep_donner, id_snow_deep_donner, id_snow_mca_donner, &
           id_enth_donner_col, id_wat_donner_col, &
           id_enth_donner_col2,  id_enth_donner_col3,  &
           id_enth_donner_col4,  id_enth_donner_col5,  &
           id_enth_donner_col6,  id_enth_donner_col7,  &
           id_enth_mca_donner_col, id_wat_mca_donner_col, &
           id_scale_donner, id_scale_donner_REV, &
           id_m_cdet_donner, id_m_cellup,   &
           id_don_precip, id_don_freq
integer :: id_max_enthalpy_imbal_don, id_max_water_imbal_don
integer :: id_vaporint, id_condensint, id_precipint, id_diffint
integer :: id_vertmotion
integer :: id_enthint, id_lprcp, id_lcondensint, id_enthdiffint
integer, dimension(:), allocatable ::    &
                                      id_tracerdt_mcadon, &
                                      id_tracerdt_mcadon_col

! uw diagnostics:
integer :: id_tdt_uw, id_qdt_uw, &
           id_qadt_uw, id_qldt_uw, id_qidt_uw, id_qndt_uw, id_qnidt_uw, &
           id_scale_uw, &
           id_uw_precip, id_uw_snow, id_uw_freq

! total convection diagnostics:
integer :: id_tdt_conv, id_qdt_conv, id_prec_conv, id_snow_conv, &
           id_conv_freq, id_gust_conv, id_mc_full, id_mc_half,   &
           id_mc_conv_up, id_conv_cld_base, id_conv_cld_top, &
           id_qadt_conv, id_qldt_conv, id_qndt_conv, id_qidt_conv, &
           id_qnidt_conv, &
           id_qa_conv_col, id_ql_conv_col, id_qn_conv_col,  &
           id_qni_conv_col, id_qi_conv_col, &
           id_q_conv_col, id_t_conv_col,              &
           id_enth_conv_col, id_wat_conv_col, &
           id_enth_uw_col, id_wat_uw_col, &
           id_prod_no, id_conv_rain3d, id_conv_snow3d
integer, dimension(:), allocatable ::    &
                                      id_tracerdt_conv,  &
                                      id_tracerdt_conv_col, &
                                      id_conv_tracer,  &
                                      id_conv_tracer_col

!  dry adjustment diagnostic:
integer :: id_tdt_dadj

!  BM diagnostics:
integer :: id_bmflag, id_klzbs, id_invtaubmt, id_invtaubmq, &
           id_massflux, id_tref, id_qref

! cape-cin diagnostics:
integer :: id_cape, id_cin, id_tp, id_rp, id_lcl, id_lfc, id_lzb

!ras diagnostics:
integer :: id_ras_precip, id_ras_freq
 

character(len=5) :: mod_name = 'moist'
character(len=8) :: mod_name2 = 'moist_tr'
real             :: missing_value = -999.


logical :: module_is_initialized = .false.



                          contains


!*******************************************************************
!
!                     PUBLIC SUBROUTINES
!
!*******************************************************************



!#######################################################################

subroutine convection_driver_init       &
             (domain, id, jd, kd, axes, Time, Physics_control, Exch_ctrl,    &
                                      Nml_mp, Control, lonb, latb, pref )
 
!---------------------------------------------------------------------
!    subroutine convection_driver_init processes convection_driver_nml,
!    saves input variables that are needed as module variables, checks for
!    consistency between specified integration choices, sets up logical
!    variables defining the integration path for convection, initializes
!    the active convective parameterization(s), and initializes the 
!    convective clocks and convective diagnostics.
!---------------------------------------------------------------------

!---------------------------------------------------------------------
type(domain2D), target,        intent(in)    :: domain !< Atmosphere domain
integer,                       intent(in)    :: id, jd, kd
integer,                       intent(in)    :: axes(4)
type(time_type),               intent(in)    :: Time
type(physics_control_type),    intent(in)    :: Physics_control
type(exchange_control_type),   intent(in)    :: Exch_ctrl
type(mp_nml_type),             intent(in)    :: Nml_mp
type(mp_removal_control_type), intent(in)    :: Control   
real, dimension(:,:),          intent(in)    :: lonb, latb
real, dimension(:),            intent(in)    :: pref
!---------------------------------------------------------------------
 
!------------------------------------------------------------------------
!      id, jd, kd  dimensions of processor window
!      axes        data axis indices, (x,y,pf,ph) for diagnostics 
!      Time        time used for diagnostics [time_type]
!      Physics_control 
!                  derived type containing control variables needed by
!                  multiple physics modules
!      Exch_ctrl   derived type variable containing control variables
!                  needed by both physics and radiation modules
!      Nml_mp      derived type variable containing the moist_processes_nml
!                  variables
!      Control     derived type variable containing control variables
!                  associated with tracer removal and transport by
!                  available convective schemes
!      lonb        longitude of grid box corners [ radians ]
!      latb        latitude of grid box corners [ radians ]
!      pref        array of reference pressures at full levels (plus 
!                  surface value at nlev+1), based on 1013.25 hPa pstar
!                  [ Pa ]
!------------------------------------------------------------------------

      integer :: secs, days  
      integer :: io, ierr, logunit

!------------------------------------------------------------------------
!      secs    seconds component of time_type variable Time
!      days    days component of time_type variable Time
!      unit    unit number used to read nml file
!      io      error return code
!      ierr    error return flag
!      logunit unit number used for stdlog file
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
      if ( module_is_initialized ) return

!-----------------------------------------------------------------------
!    process the convection_driver_nml.
!-----------------------------------------------------------------------
      if ( file_exists('input.nml')) then
        read (input_nml_file, nml=convection_driver_nml, iostat=io)
        ierr = check_nml_error(io,'convection_driver_nml')
!----------------------------------------------------------------------
!    write version and namelist to standard logfile.
!----------------------------------------------------------------------
        call write_version_number ( version, tagname )
        logunit = stdlog()
        if ( mpp_pe() == mpp_root_pe() ) &
                        write ( logunit, nml=convection_driver_nml )
      endif

!----------------------------------------------------------------------
!    define needed module variables supplied by the derived types input 
!    to this subroutine.
!----------------------------------------------------------------------
      qmin = Exch_ctrl%qmin
      do_liq_num = Exch_ctrl%do_liq_num
      do_ice_num = Exch_ctrl%do_ice_num
      do_clubb = Exch_ctrl%do_clubb
      do_lsc = Nml_mp%do_lsc
      do_cosp = Exch_ctrl%do_cosp
      do_mca = Nml_mp%do_mca
      do_ras = Nml_mp%do_ras
      do_uw_conv = Nml_mp%do_uw_conv
      do_donner_deep = Nml_mp%do_donner_deep
      limit_conv_cloud_frac = Nml_mp%limit_conv_cloud_frac
      do_dryadj = Nml_mp%do_dryadj
      include_donmca_in_cosp = Nml_mp%include_donmca_in_cosp
      do_rh_clouds_BM = Nml_mp%do_rh_clouds
      do_bm = Nml_mp%do_bm
      do_bmmass = Nml_mp%do_bmmass
      do_bmomp  = Nml_mp%do_bmomp 
      do_simple = Nml_mp%do_simple
      doing_prog_clouds = Exch_ctrl%doing_prog_clouds
      nsphum = Physics_control%nsphum
      nql = Physics_control%nql
      nqi = Physics_control%nqi
      nqa = Physics_control%nqa
      nqn = Physics_control%nqn
      nqni = Physics_control%nqni
      nqr = Physics_control%nqr
      nqs = Physics_control%nqs
      nqg = Physics_control%nqg
      num_prog_tracers = Physics_control%num_prog_tracers

      num_donner_tracers = Control%num_donner_tracers
      num_mca_tracers = Control%num_mca_tracers
      num_ras_tracers = Control%num_ras_tracers
      num_uw_tracers = Control%num_uw_tracers
 
      allocate (tracers_in_donner (num_prog_tracers))
      allocate (tracers_in_ras (num_prog_tracers))
      allocate (tracers_in_mca (num_prog_tracers))
      allocate (tracers_in_uw (num_prog_tracers))

      tracers_in_donner = Control%tracers_in_donner
      tracers_in_ras    = Control%tracers_in_ras   
      tracers_in_mca    = Control%tracers_in_mca   
      tracers_in_uw     = Control%tracers_in_uw    

      allocate (cloud_tracer(size(Physics_control%cloud_tracer)))
      cloud_tracer = Physics_control%cloud_tracer

!-----------------------------------------------------------------------
!    check to make sure that unavailable convection implementations have
!    not been specified.
!-----------------------------------------------------------------------
      if (do_mca .and. do_ras ) call error_mesg   &
         ('convection_driver_init',  &
               'both do_mca and do_ras cannot be specified', FATAL)

      if (do_mca .and. do_bm ) call error_mesg   &
         ('convection_driver_init',  &
                    'both do_mca and do_bm cannot be specified', FATAL)
      if (do_ras .and. do_bm ) call error_mesg   &
         ('convection_driver_init',  &
                     'both do_bm and do_ras cannot be specified', FATAL)
      if (do_bm .and. do_bmmass ) call error_mesg   &
         ('convection_driver_init',  &
                   'both do_bm and do_bmmass cannot be specified', FATAL)
      if (do_bm .and. do_bmomp ) call error_mesg   &
         ('convection_driver_init',  &
                   'both do_bm and do_bmomp cannot be specified', FATAL)
      if (do_bmomp .and. do_bmmass ) call error_mesg   &
         ('convection_driver_init',  &
             'both do_bmomp and do_bmmass cannot be specified', FATAL)
      if (do_bmmass .and. do_mca ) call error_mesg   &
         ('convection_driver_init',  &
             'both do_bmmass and do_mca cannot be specified', FATAL)
      if (do_bmmass .and. do_ras ) call error_mesg   &
         ('convection_driver_init',  &
                  'both do_bmmass and do_ras cannot be specified', FATAL)
      if (do_bmomp .and. do_mca ) call error_mesg   &
         ('convection_driver_init',  &
                 'both do_bmomp and do_mca cannot be specified', FATAL)
      if (do_bmomp .and. do_ras ) call error_mesg   &
         ('convection_driver_init',  &
                 'both do_bmomp and do_ras cannot be specified', FATAL)

      if (do_mca .and. do_donner_deep) call error_mesg &
         ('convection_driver_init',  &
             'do_donner_deep and do_mca cannot both be active', FATAL)

!----------------------------------------------------------------------
!    define logical controls indicating the status of the available
!    convective implementations in this experiment.
!----------------------------------------------------------------------
      if (do_dryadj) then
        if (do_mca) then
          ldcamca = .true.
        else
          ldca = .true.
        endif
      else if (do_mca) then
          lmca = .true.
      else if (do_ras) then
          if (do_donner_deep) then
            ldonnerras = .true.
          else
            lras = .true.
          endif
      else if (do_uw_conv) then
          if (do_donner_deep) then
            if (do_donner_before_uw) then
              ldonner_then_uw = .true.
            else
              luw_then_donner = .true. 
            endif
          else
            luwconv = .true.
          endif           
      else if (do_donner_deep) then
          ldonner = .true.
      else if (do_bm) then
          lbm = .true.
      else if (do_bmmass) then
          lbmmass = .true.
      else if (do_bmomp) then
          lbmomp = .true.
      endif
      
!----------------------------------------------------------------------
!    check for inconsistent / invalid settings involving 
!    convection_driver_nml variables.
!----------------------------------------------------------------------
      if (do_donner_deep) then 
        if (include_donmca_in_cosp .and. (.not. do_donner_mca) ) &
          call error_mesg ('convection_driver_init', &
             'trying to include donmca in COSP when donmca is inactive', &
                                                                  FATAL)
        if (do_cosp .and. .not. (do_donner_conservation_checks)) then
          do_donner_conservation_checks = .true.
          call error_mesg ('convection_driver_init', &
              'setting do_donner_conservation_checks to true so that &
                 &needed fields for COSP are produced.', NOTE)
        endif
      endif

      if (force_donner_moist_conserv .and.    &
                                 .not. do_donner_conservation_checks) then
        call error_mesg ('convection_driver_init', &
              'when force_donner_moist_conserv is .true., &
                &do_donner_conservation_checks must be .true.', FATAL)
      endif
 
      if (use_updated_profiles_for_uw .and.   &     
                            .not. (do_donner_before_uw) ) then
        call error_mesg ('convection_driver_init', &
         'use_updated_profiles_for_uw is only meaningful when &
                              &do_donner_before_uw is true', FATAL)
      endif

      if (use_updated_profiles_for_donner .and.   &     
                             (do_donner_before_uw) ) then
        call error_mesg ('convection_driver_init', &
         'use_updated_profiles_for_donner is only meaningful when &
                              &do_donner_before_uw is false', FATAL)
      endif

      if (only_one_conv_scheme_per_column .and.   &
                .not. (do_donner_before_uw) ) then
        call error_mesg ('convection_driver_init', &
          'only_one_conv_scheme_per_column is only meaningful when &
                             &do_donner_before_uw is true', FATAL)
      endif
 
      if (limit_conv_cloud_frac .and.  (.not. do_donner_before_uw)) then
        call error_mesg ('convection_driver_init', &
            'when limit_conv_cloud_frac is .true., &
                             &do_donner_before_uw must be .true.', FATAL)
      endif

      if (do_unified_convective_closure) then
        call error_mesg ('convection_driver_init', &
         'do_unified_convective_closure is currently not allowed', FATAL)
      endif

      if (do_cmt) then
        if ( .not. do_ras .and. .not. do_donner_deep  .and. &
                                          .not. do_uw_conv) then
          call error_mesg ( 'convection_driver_init', &
                'do_cmt is active but no cumulus schemes activated', &
                                                              FATAL)
        endif
      endif

!-----------------------------------------------------------------------
!    initialize the convective parameterizations that are active in this 
!    experiment.
!-----------------------------------------------------------------------
      if (do_dryadj) call dry_adj_init ()
      if (do_bm)     call betts_miller_init () 
      if (do_bmmass) call bm_massflux_init()
      if (do_bmomp)  call bm_omp_init () 

!-------------------------------------------------------------------------
!    initialize the cumulus momentum transport module, defining logicals 
!    indicating which convective schemes are to be seen by that module.
!-------------------------------------------------------------------------
      if (do_cmt) then
        call cu_mo_trans_init (axes, Time, Nml_mp, cmt_mass_flux_source)
      endif 

!--------------------------------------------------------------------
!    continue the initialization of the convection scheme modules.
!--------------------------------------------------------------------
      if (do_donner_deep) then
        call get_time (Time, secs, days)
        call donner_deep_init (domain, lonb, latb, pref, axes, secs, days,  &
                               Control%tracers_in_donner,  &
                               do_donner_conservation_checks, &
                               do_unified_convective_closure, &
                               doing_prog_clouds)
        if (do_donner_conservation_checks) then
          allocate (max_enthalpy_imbal_don (id, jd))
          allocate (max_water_imbal_don (id, jd))
          max_enthalpy_imbal_don = 0.
          max_water_imbal_don = 0.
        endif
      endif ! (do_donner_deep)
 
      if (do_ras)  then
        call ras_init (doing_prog_clouds, do_liq_num, axes, Time, Nml_mp, &
                                                    Control%tracers_in_ras)
      endif

      if (do_uw_conv) call uw_conv_init (doing_prog_clouds, axes, Time,   &
                                         kd, Nml_mp, Control%tracers_in_uw)

      if (do_mca .or. do_donner_mca)  then
        call  moist_conv_init (axes, Time, Control%tracers_in_mca)
      endif

!-----------------------------------------------------------------------
!    initialize clocks.
!-----------------------------------------------------------------------
      convection_clock = mpp_clock_id( '   Physics_up: Moist Proc: Conv' ,&
                                             grain=CLOCK_MODULE_DRIVER )
      donner_clock     = mpp_clock_id( '   Moist Processes: Donner_deep' ,&
                                             grain=CLOCK_MODULE_DRIVER )
      dca_clock        = mpp_clock_id( '   Moist Processes: DCA'         ,&
                                             grain=CLOCK_MODULE_DRIVER )
      mca_clock        = mpp_clock_id( '   Moist Processes: MCA'         ,&
                                             grain=CLOCK_MODULE_DRIVER )
      donner_mca_clock = mpp_clock_id( '   Moist Processes: Donner_MCA'  ,&
                                             grain=CLOCK_MODULE_DRIVER )
      ras_clock        = mpp_clock_id( '   Moist Processes: RAS'         ,&
                                             grain=CLOCK_MODULE_DRIVER )
      uw_clock         = mpp_clock_id( '   Moist Processes: UW'  ,&
                                             grain=CLOCK_MODULE_DRIVER )
      cmt_clock        = mpp_clock_id( '   Moist Processes: CMT'         ,&
                                             grain=CLOCK_MODULE_DRIVER )
      bm_clock         = mpp_clock_id( '   Moist Processes: Betts-Miller',&
                                             grain=CLOCK_MODULE_DRIVER )
 
!------------------------------------------------------------------------
!    call diag_field_init to register the netcdf diagnostic fields.
!------------------------------------------------------------------------
      call diag_field_init (axes, Time, Control)

!------------------------------------------------------------------------
!    initialize the ice number detrain module.
!------------------------------------------------------------------------
      call detr_ice_num_init

!---------------------------------------------------------------------
      module_is_initialized = .true.


end subroutine convection_driver_init


!#######################################################################

subroutine convection_driver_time_vary    &
                     (Time_in, dt_in, i_cell_in, i_meso_in, i_shallow_in)

!------------------------------------------------------------------------
!    subroutine convection_driver_time_vary saves needed input arguments
!    as module variables for use within the prognostic spatial loops 
!    and verifies that needed cloud inputs will be available.
!------------------------------------------------------------------------

!-------------------------------------------------------------------------
type(time_type), intent(in) :: Time_in 
real,            intent(in) :: dt_in  
integer,         intent(in) :: i_cell_in, i_meso_in, i_shallow_in
!-------------------------------------------------------------------------

!-------------------------------------------------------------------------
!    Time_in       ! time used for diagnostics [ time_type ]
!    dt_in         ! time step [ seconds ]
!    i_cell_in     ! index in cloud arrays for donner cell clouds
!    i_meso_in     ! index in cloud arrays for donner meso clouds
!    i_shallow_in  ! index in cloud arrays for uw clouds
!-------------------------------------------------------------------------

!---------------------------------------------------------------------
!    verify that the module has been initialized.
!---------------------------------------------------------------------
      if (.not. module_is_initialized) then
        call error_mesg (   &
                 'convection_driver_mod/convection_driver_time_vary',  &
                     'convection_driver_init has not been called.', FATAL)
      endif

!------------------------------------------------------------------------
!    save the input arguments as module variables of this module. Pass them
!    to dependent modules as required.
!------------------------------------------------------------------------
      dt = dt_in
      dtinv = 1./dt
      if (do_donner_deep) then
        call donner_deep_time_vary (dt)
      endif

      i_cell = i_cell_in
      i_meso = i_meso_in
      i_shallow = i_shallow_in

      Time     = Time_in

!---------------------------------------------------------------------
!    if donner parameterization is active,  be sure the donner cloud field 
!    arguments are valid.
!---------------------------------------------------------------------
      if (do_donner_deep) then
        if (i_cell /= 0 .and. i_meso /= 0 ) then  
        else
          call error_mesg ('convection_driver_mod',   &
               'input args for donner clouds not correct', FATAL)
        endif
      endif

!---------------------------------------------------------------------
!    if uw parameterization is active, be sure the uw cloud field argument 
!    is valid.
!---------------------------------------------------------------------
      if (do_uw_conv) then
        if (i_shallow /= 0) then
        else
          call error_mesg ('convection_driver_mod',   &
                  'input args for uw shallow clouds not correct', FATAL)
        endif
      endif

!----------------------------------------------------------------------


end subroutine convection_driver_time_vary


!########################################################################

subroutine convection_driver   &
                   (is, ie, js, je, Surf_diff, Phys_mp_exch, &
                       Moist_clouds_block, Input_mp, Tend_mp, C2ls_mp, &
                                          Output_mp, Removal_mp, Aerosol)

!------------------------------------------------------------------------
!    subroutine convection_driver saves needed variables on input for
!    later use, calls the driver routines for the activated convective
!    implementation to compute convective effects on the model variables,
!    computes cumulus momentum transport and other effects of convection,
!    and outputs various convective diagnostics.
!------------------------------------------------------------------------

integer,                intent(in)           :: is, ie, js, je
type(surf_diff_type),   intent(in)           :: Surf_diff
type(phys_mp_exch_type),intent(inout)        :: Phys_mp_exch
type(clouds_from_moist_block_type), &
                        intent(inout)        :: Moist_clouds_block
type(mp_input_type),    intent(inout)        :: Input_mp
type(mp_tendency_type), intent(inout)        :: Tend_mp
type(mp_conv2ls_type),  intent(inout)        :: C2ls_mp
type(mp_output_type),   intent(inout)        :: Output_mp
type(mp_removal_type),  intent(inout)        :: Removal_mp
type(aerosol_type),     intent(in), optional :: Aerosol

!-----------------------------------------------------------------------
!    is,ie      starting and ending i indices for window
!    js,je      starting and ending j indices for window
!    Surf_diff  derived type which will transport surface fluxes from
!               atmos_model to convection_driver  via physics_driver
!               and moist_processes (not yet implemented)
!    Phys_mp_exch 
!               derived type used to transfer data between physics_driver
!               and convection_driver via moist_processes
!    Moist_clouds_block 
!               derived type used to transfer cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Aerosol    derived type containing model aerosol fields to be input
!               to model convective schemes
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------

      type(conv_results_type) :: Conv_results
      integer                 :: ix, jx, kx, nt

!-----------------------------------------------------------------------
!    Conv_results     derived type variable containing convective results
!                     that are collected during integration and passed to
!                     the diagnostics output subroutine.                  
!    ix, jx, kx       i, j, and k dimensions of the current physics_window
!    nt               number of activated prognostic tracers
!-----------------------------------------------------------------------

!---------------------------------------------------------------------
!    turn on the convective parameterizations clock.
!---------------------------------------------------------------------
      call mpp_clock_begin (convection_clock)

!---------------------------------------------------------------------
!    verify that the module has been initialized.
!---------------------------------------------------------------------
      if (.not. module_is_initialized) then
        call error_mesg ('convection_driver_mod',  &
                 'convection_driver_init has not been called.', FATAL)
      endif

!-----------------------------------------------------------------------
!    be sure optional argument is present if needed.
!-----------------------------------------------------------------------
      if (present(Aerosol)) then
      else
        if (do_uw_conv .or. (do_ras .and. do_liq_num)) then
          call error_mesg ('convection_driver_mod',  &
            'Aerosol argument required when either do_uw_conv or ras with&
               &  prognostic droplet number is activated.', FATAL)
        endif
      endif

!-----------------------------------------------------------------------
!    save the value of rdt upon entry to the routine so that the total
!    convective contribution to the tendency (as defined by this module)
!    may later be defined.
!    save input temperature, specific humidity and tracer fields. the 
!    original values may be needed by multiple parameterizations called 
!    from within this module; however, these values may be updated within
!    this module, so those values would not be available.
!-----------------------------------------------------------------------
      Output_mp%rdt_init = Output_mp%rdt
      Input_mp%tin_orig = Input_mp%tin
      Input_mp%qin_orig = Input_mp%qin
      Input_mp%tracer_orig = Input_mp%tracer

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 
      nt = size(Output_mp%rdt,4)

!--------------------------------------------------------------------
!    call convection_driver-alloc to allocate and initialize the components
!    of the conv_results_type variable Conv_results.
!--------------------------------------------------------------------
      call convection_driver_alloc (ix, jx, kx, Conv_results)


!&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&
!&                                                                      &
!&               AVAILABLE CONVECTIVE IMPLEMENTATIONS                   &
!&                                                                      &
!&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&

!------------------------------------------------------------------------
!    integrate the active convective implementation.
!------------------------------------------------------------------------
      

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         DRY CONVECTIVE ADJUSTMENT          @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if dry adjustment only is desired call subroutine dca_driver.
!---------------------------------------------------------------------
      if (ldca) then
        call dca_driver (is, js, Input_mp, Output_mp, Tend_mp)


!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         MOIST CONVECTIVE ADJUSTMENT        @    
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if moist adjustment only is desired call subroutine mca_driver.
!---------------------------------------------------------------------
      else if (lmca) then
        call mca_driver  (is, js, Input_mp, Output_mp, Tend_mp )

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         DRY CONVECTIVE ADJUSTMENT AND      @
!        @         MOIST CONVECTIVE ADJUSTMENT        @    
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if both dry and moist convective adjustment are desired call 
!    subroutines dca_driver and mca_driver.
!---------------------------------------------------------------------
      else if (ldcamca) then
        call dca_driver (is, js, Input_mp, Output_mp, Tend_mp)
        call mca_driver (is, js, Input_mp, Output_mp, Tend_mp)

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         UW CONVECTION SCHEME ONLY          @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if only the uw convection scheme is desired call subroutine 
!    uw_conv_driver.
!---------------------------------------------------------------------
      else if (luwconv) then
        call uw_conv_driver    &
                ( is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                  Output_mp, Tend_mp, Conv_results, Removal_mp,      &
                                 Moist_clouds_block%cloud_data(i_shallow))

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         UW CONVECTION SCHEME, FOLLOWED BY  @
!        @         DONNER CONVECTION SCHEME           @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if the uw convection scheme followed by a call to the donner scheme
!    is desired, call subroutine uw_then_donner_driver.
!---------------------------------------------------------------------
      else if (luw_then_donner ) then
        call uw_then_donner_driver &
                ( is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                   Output_mp, Tend_mp, Conv_results, Removal_mp,     &
                     Moist_clouds_block, C2ls_mp)


!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @         DONNER CONVECTION SCHEME, FOLLOWED @
!        @         BY UW CONVECTION SCHEME            @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if  the donner scheme followed by uw convection is desired, call 
!    donner_driver to execute the donner_deep parameterization:
!---------------------------------------------------------------------
      else if (ldonner_then_uw) then
        call donner_driver ( is, ie, js, je, Input_mp,             &
                             Moist_clouds_block, Conv_results,          &
                             C2ls_mp, Removal_mp, Tend_mp, Output_mp)

!---------------------------------------------------------------------
!    then call the uw_conv wrapper routine:
!---------------------------------------------------------------------
        call uw_conv_driver   &
                ( is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                   Output_mp, Tend_mp, Conv_results, Removal_mp,   &
                                 Moist_clouds_block%cloud_data(i_shallow))

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @        DONNER CONVECTION SCHEME ONLY       @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if only the donner scheme is desired, call donner_driver to execute 
!    the donner_deep parameterization.
!---------------------------------------------------------------------
      else if (ldonner) then
        call donner_driver ( is, ie, js, je, Input_mp,             &
                             Moist_clouds_block, Conv_results,           &
                             C2ls_mp, Removal_mp, Tend_mp, Output_mp )

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @        BETTS-MILLER CONVECTION SCHEME      @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!----------------------------------------------------------------------
!    if one of the betts-miller convection schemes is active, call the 
!    betts-miller driver subroutine.
!----------------------------------------------------------------------
      else if ( any((/do_bm, do_bmmass, do_bmomp/)) ) then
        call betts_miller_driver (is, js, Input_mp, Output_mp, Tend_mp)


!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @        DONNER CONVECTION SCHEME FOLLOWED   @
!        @        BY RELAXED ARAKAWA-SCHUBERT SCHEME  @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!---------------------------------------------------------------------
!    if the donner scheme followed by the ras scheme is desired, call 
!    donner_driver to execute the donner_deep parameterization:
!---------------------------------------------------------------------
      else if (ldonnerras) then
        call donner_driver (is, ie, js, je, Input_mp,             &
                               Moist_clouds_block, Conv_results,       &
                                  C2ls_mp, Removal_mp, Tend_mp, Output_mp)

!-----------------------------------------------------------------------
!    then call ras_driver to execute relaxed arakawa/schubert cumulus 
!    parameterization scheme:
!-----------------------------------------------------------------------
        call ras_driver   &
            (is, js, Input_mp, Output_mp, Tend_mp, Conv_results,   &
                                                       C2ls_mp, Aerosol)

!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
!        @                                            @
!        @     RELAXED ARAKAWA-SCHUBERT SCHEME        @
!        @                                            @
!        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!-----------------------------------------------------------------------
!    if only the ras scheme is desired, call ras_driver to execute the
!    relaxed arakawa/schubert cumulus parameterization scheme.
!-----------------------------------------------------------------------
      else if (lras) then
        call ras_driver   &
            (is, js, Input_mp,  Output_mp, Tend_mp, Conv_results,   &
                                                       C2ls_mp, Aerosol)

      else

!-----------------------------------------------------------------------
!    if no available convective implementations were requested, exit 
!    with an error message.
!-----------------------------------------------------------------------
        call error_mesg ('convection_driver',    &
                        'no convective implementation specified', FATAL)
      endif

!&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&
!&                                                                      &
!&             END OF INDIVIDUAL CONVECTIVE SCHEMES                     &
!&                                                                      &
!&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&


!---------------------------------------------------------------------
!    now that all potential convection schemes have been processed, 
!    calculate cumulus momentum transport, if desired. 
!---------------------------------------------------------------------
      if (do_cmt) then

!----------------------------------------------------------------------
!    activate the cmt clock, call cu_mo_trans, and then deactivate 
!    the clock.
!----------------------------------------------------------------------
        call mpp_clock_begin (cmt_clock)
        call cu_mo_trans (is, js, Time, dt, num_prog_tracers, Input_mp, &
                         Conv_results, Output_mp, Tend_mp%ttnd_conv)
        call mpp_clock_end (cmt_clock)
      endif 

!------------------------------------------------------------------------
!    call define_total_convective_output to  a) define total cloud mass
!    flux, b) define cloud base and cloud top, c) define lightning
!    source of nox, d) define convective gustiness, e) set flag indicating
!    columns with convection, f) update the Input_mp%tracer field with
!    the changes produced in this module, and g) update the tin and
!    rdt fields with the uw tendencies if they have not already been so
!    updated. Updating fields at this point only occurs when legacy warsaw 
!    results are desired; otherwise the updates would have been done at
!    the more appropriate time.
!------------------------------------------------------------------------
      call define_total_convective_output (is, js, nt, C2ls_mp,  &
                          Conv_results, Input_mp, Output_mp, Phys_mp_exch) 

!------------------------------------------------------------------------
!    call convective_diagnostics to produce and output desired diagnostics
!    reflecting the model's total convection, summed over the active
!    convective parameterization(s).      
!------------------------------------------------------------------------
      call convective_diagnostics (is, js, C2ls_mp, Conv_results,  &
                                           Input_mp, Tend_mp, Output_mp)

!-----------------------------------------------------------------------
!    call define_convective_area to compute the grid box area taken up by 
!    convective clouds, so that this information may be supplied to the 
!    large-scale cloud module.  
!-----------------------------------------------------------------------
      call define_convective_area    &
                      (C2ls_mp, Moist_clouds_block, Input_mp)

!----------------------------------------------------------------------
!    define the interface-level precip fluxes needed for input to the 
!    COSP simulator package.
!---------------------------------------------------------------------
      if (do_cosp) then
        call define_inputs_for_cosp (Removal_mp)
      endif
!------------------------------------------------------------------------
!    deallocate the components of the Conv_results derived type variable.
!------------------------------------------------------------------------
      call convection_driver_dealloc (Conv_results)

!---------------------------------------------------------------------
!    end the timing of the convection code section.
!---------------------------------------------------------------------
      call mpp_clock_end (convection_clock)


!------------------------------------------------------------------------


end subroutine convection_driver


!######################################################################

subroutine convection_driver_endts 

!-----------------------------------------------------------------------
!    subroutine convection_driver_endts performs needed calculations 
!    upon exiting the prognostic loop.
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    if donner convection is active, call the end-of-timestep routine of 
!    that module.
!-----------------------------------------------------------------------
      if (do_donner_deep) then
        call donner_deep_endts
      endif 

!-----------------------------------------------------------------------


end subroutine convection_driver_endts

!########################################################################

subroutine convection_driver_end 

!--------------------------------------------------------------------- 
!    subroutine convection_driver_end calls destructor routines for the
!    modules initialized within this module, and deallocates module
!    variables.
!--------------------------------------------------------------------- 

!--------------------------------------------------------------------- 
!    call the destructor routines for the active convection modules.
!--------------------------------------------------------------------- 
      if (do_donner_deep) call donner_deep_end 
      if (do_ras        ) call ras_end 
      if (do_uw_conv    ) call uw_conv_end 
      if (do_cmt        ) call cu_mo_trans_end 
      call detr_ice_num_end 

!----------------------------------------------------------------------
!    deallocate module variables.
!----------------------------------------------------------------------
      if (do_donner_deep .and. do_donner_conservation_checks) then 
        deallocate (max_water_imbal_don) 
        deallocate (max_enthalpy_imbal_don)
      endif

      deallocate (tracers_in_donner)
      deallocate (tracers_in_uw    )
      deallocate (tracers_in_mca   )
      deallocate (tracers_in_ras   )

      deallocate (cloud_tracer)

      deallocate(id_tracerdt_conv)        ! h1g, 2017-02-02
      deallocate (id_tracerdt_conv_col)   ! h1g, 2017-02-02
      deallocate (id_conv_tracer)         ! h1g, 2017-02-02
      deallocate (id_conv_tracer_col)     ! h1g, 2017-02-02
      if (do_donner_mca) then
        deallocate ( id_tracerdt_mcadon )        ! h1g, 2017-02-02
        deallocate ( id_tracerdt_mcadon_col )    ! h1g, 2017-02-02
      endif

!--------------------------------------------------------------------

   
 end subroutine convection_driver_end



!######################################################################

subroutine convection_driver_restart (timestamp)

!------------------------------------------------------------------------
!    subroutine convection_driver_restart controls the writing of any 
!    restart files associated with activated convection schemes.
!------------------------------------------------------------------------

character(len=*), intent(in), optional :: timestamp

!-----------------------------------------------------------------------
!       timestamp   character string that represents the model time, 
!                   used for writing restart. timestamp will append to
!                   the any restart file name as a prefix.
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    process the donner convection restart file.
!-----------------------------------------------------------------------
      if (do_donner_deep) call donner_deep_restart (timestamp)

!-----------------------------------------------------------------------


end subroutine convection_driver_restart


!#######################################################################

subroutine cape_cin_diagnostics (is, ie, js, je, Input_mp, Time)

!-----------------------------------------------------------------------
!    subroutine cape_cin_diagnostics calls subroutine capecalcnew to 
!    compute a parcel's ascent, computing cape and cin of the 
!    environment as it does, if diagnostics for cape or cin are requested, 
!-----------------------------------------------------------------------

integer,             intent(in) :: is, ie, js, je
type(mp_input_type), intent(in) :: Input_mp
type(time_type),     intent(in) :: Time

!-----------------------------------------------------------------------
!    is,ie      starting and ending i indices for window
!    js,je      starting and ending j indices for window
!    Input_mp   derived type variable containing model profiles
!    Time       variable containing current diagnostic time [ time_type ]
!-----------------------------------------------------------------------

      real, dimension(size(Input_mp%tin,1), size(Input_mp%tin,2),  &
                                            size(Input_mp%tin,3)) ::  &
                                                             rin, rp, tp
      real, dimension(size(Input_mp%tin,1), size(Input_mp%tin,2)) ::  &
                                                                cape, cin
      integer, dimension(size(Input_mp%tin,1), size(Input_mp%tin,2)) ::  &
                                                       klcl, klfc, klzb

      logical :: avgbl, used
      integer :: i, j, ix, jx, kx
 
!--------------------------------------------------------------------
!    rin          model h2o mixing ratio [ kg [h2o] / kg [dry air ] 
!    rp           rising parcel mixing ratio profile
!    tp           rising parcel temperature profile
!    cape         convective available potential energy
!    cin          convective inhibition
!    klcl         model lifting condensation level for rising parcel
!    klfc         model level of free convection for rising parcel
!    klzb         model level of zero buoyancy for rising parcel
!    avgbl        outdated variable no longer used in capecalcnew
!    used         logical used to indicate data has been received by
!                 diag_manager_mod
!    i, j         do loop indices
!    ix, jx, kx   array  spatial dimensions; size of physics_window
!------------------------------------------------------

!-------------------------------------------------------------------
!    proceed with computation if diagnostics for cape or cin are requested,
!------------------------------------------------------------------
      if ( id_cape > 0 .or. id_cin > 0) then

!---------------------------------------------------------------------
!    define physics window dimensions.
!--------------------------------------------------------------------
        kx = size(Input_mp%tin,3)
        ix = size(Input_mp%tin,1)
        jx = size(Input_mp%tin,2)

!----------------------------------------------
!    calculate mixing ratio.
!----------------------------------------------
        rin = Input_mp%qin/(1.0 - Input_mp%qin) 

!-----------------------------------------------------------------------
!    call routine to calculate cape and cin based on parcel rise.
!-----------------------------------------------------------------------
        avgbl = .false.
        do j = 1,jx 
          do i = 1,ix 
            call capecalcnew   &
                ( kx, Input_mp%pfull(i,j,:), Input_mp%phalf(i,j,:),   &
                  CP_AIR, RDGAS, RVGAS, HLV, KAPPA, Input_mp%tin(i,j,:), &
                  rin(i,j,:), avgbl, cape(i,j), cin(i,j), tp(i,j,:), &
                  rp(i,j,:), klcl(i,j), klfc(i,j), klzb(i,j))
          end do
        end do

!-------------------------------------------------------------------------
!    output any requested diagnostics.
!-------------------------------------------------------------------------
        if (id_cape > 0) used = send_data ( id_cape, cape, Time, is, js )
        if ( id_cin > 0 ) used = send_data ( id_cin, cin, Time, is, js )
        if ( id_tp  > 0 ) used = send_data ( id_tp,  tp, Time, is, js )
        if ( id_rp  > 0 ) used = send_data ( id_rp,  rp, Time, is, js )
        if ( id_lcl > 0 ) used = send_data ( id_lcl, 1.0*klcl, Time,  &
                                                                 is, js )
        if ( id_lfc > 0 ) used = send_data ( id_lfc, 1.0*klfc, Time,  &
                                                                 is, js )
        if ( id_lzb > 0 ) used = send_data ( id_lzb, 1.0*klzb, Time,  &
                                                                 is, js )
      end if

!-----------------------------------------------------------------------



end subroutine cape_cin_diagnostics



!*******************************************************************
!
!                     PRIVATE INITIALIZATION SUBROUTINES
!
!*******************************************************************



!#########################################################################

subroutine diag_field_init ( axes, Time, Control)

!-----------------------------------------------------------------------
!    this subroutine initializes diagnostic fields from this module. it
!    also initializes global integrals for netCDF output.
!-----------------------------------------------------------------------

integer,                       intent(in) :: axes(4)
type(time_type),               intent(in) :: Time
type(mp_removal_control_type), intent(in) :: Control

!------------------------------------------------------------------------

!------------------------------------------------------------------------
!      axes        data axis indices, (x,y,pf,ph) for diagnostics 
!      Time        time used for diagnostics [time_type]
!      Control     derived type variable containing control variables
!                  associated with tracer removal and transport by
!                  available convective schemes
!------------------------------------------------------------------------

      character(len=32)     :: tracer_units, tracer_name
      character(len=128)    :: diaglname
      integer, dimension(3) :: half = (/1,2,4/)
      integer               :: n, nn

!-----------------------------------------------------------------------
!      tracer_units  units assigned to each tracer field
!      tracer_name   name assigned to each tracer field
!      diaglname     long name associated with each tracer diagnostic field
!      half          axis indices for x, y and model half-levels
!      n             do loop index
!      nn            counter for subset of tracers meeting a particular
!                    condition
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    initialize global integrals for netCDF output.
!-----------------------------------------------------------------------
      id_pr_g = register_global_diag_field ('pr', Time, 'Precipitation', &
                  'kg m-2 s-1', standard_name='precipitation_flux',   &
                                                           buffer=.true. )
      id_prc_g = register_global_diag_field ('prc', Time,    &
                  'Convective Precipitation', 'kg m-2 s-1',   &
                        standard_name='convective_precipitation_flux', &
                                                           buffer=.true. )
      id_prsn_g = register_global_diag_field ('prsn', Time,    &
                  'Snowfall Flux', 'kg m-2 s-1', &
                            standard_name='snowfall_flux', buffer=.true. )

!-------------------------------------------------------------------------
!    diagnostics related to total convective tendencies of temperature,
!    vapor and precipitation.
!-------------------------------------------------------------------------
      id_tdt_conv = register_diag_field ( mod_name, &
                   'tdt_conv', axes(1:3), Time, &
                   'Temperature tendency from convection ',  'deg_K/s',  &
                                           missing_value=missing_value)

      ID_tntc = register_cmip_diag_field_3d ( mod_name, 'tntc', Time, &
                  'Tendency of Air Temperature Due to Convection ',   &
                      'K s-1', standard_name=      &
                          'tendency_of_air_temperature_due_to_convection' )

      id_qdt_conv = register_diag_field ( mod_name, &
                  'qdt_conv', axes(1:3), Time, &
                  'Spec humidity tendency from convection ',  'kg/kg/s',  &
                                            missing_value=missing_value)

      ID_tnhusc = register_cmip_diag_field_3d ( mod_name, 'tnhusc', Time, &
                  'Tendency of Specific Humidity Due to Convection ',   &
                     's-1', standard_name=   &
                        'tendency_of_specific_humidity_due_to_convection' )

      id_q_conv_col = register_diag_field ( mod_name, &
                      'q_conv_col', axes(1:2), Time, &
                      'Water vapor path tendency from convection ',  &
                                                              'kg/m2/s' )
   
      id_t_conv_col = register_diag_field ( mod_name, &
                      't_conv_col', axes(1:2), Time, &
                      'Column static energy tendency from convection ', &
                                                                'W/m2' )
   
      id_enth_conv_col = register_diag_field ( mod_name, &
                         'enth_conv_col', axes(1:2), Time, &
                         'Column enthalpy tendency from convection',  &
                                                                'W/m2' )
 
      id_wat_conv_col = register_diag_field ( mod_name, &
                        'wat_conv_col', axes(1:2), Time, &
                        'Column total water tendency from convection', &
                                                        'kg(h2o)/m2/s' )

      id_prec_conv = register_diag_field ( mod_name, &
                     'prec_conv', axes(1:2), Time, &
                     'Precipitation rate from convection ',    &
                     'kg(h2o)/m2/s', interp_method = "conserve_order1" )

      id_prc = register_cmip_diag_field_2d ( mod_name, 'prc', Time, &
                        'Convective Precipitation',   'kg m-2 s-1', &
                    standard_name = 'convective_precipitation_flux', &
                                  interp_method = "conserve_order1" ) 
 
      id_prrc = register_cmip_diag_field_2d ( mod_name, 'prrc', Time, &
                             'Convective Rainfall Rate', 'kg m-2 s-1', &
                             standard_name='convective_rainfall_flux', &
                                       interp_method="conserve_order1" )

      id_snow_conv = register_diag_field ( mod_name, &
                     'snow_conv', axes(1:2), Time, &
                     'Frozen precip rate from convection ',  &
                     'kg(h2o)/m2/s', interp_method = "conserve_order1" )

      id_conv_freq = register_diag_field ( mod_name, &
                     'conv_freq', axes(1:2), Time, &
                     'frequency of convection ',       '1', &
                     missing_value = missing_value, &
                      interp_method = "conserve_order1"      )

      id_prsnc = register_cmip_diag_field_2d ( mod_name, 'prsnc', Time, &
                              'Convective Snowfall Flux', 'kg m-2 s-1', &
                               standard_name='convective_snowfall_flux', &
                                         interp_method="conserve_order1" )

      id_ci = register_cmip_diag_field_2d ( mod_name, 'ci', Time, &
                 'Fraction of Time Convection Occurs in Cell',  '1.0',  &
                             standard_name='convection_time_fraction', &
                             interp_method = "conserve_order1" )

      id_gust_conv = register_diag_field ( mod_name, &
                     'gust_conv', axes(1:2), Time, &
                          'Gustiness resulting from convection ', 'm/s' )

      id_conv_rain3d= register_diag_field ( mod_name, &
                   'conv_rain3d', axes(half), Time, &
                      'Rain fall rate from convection -3D ',    &
                        'kg(h2o)/m2/s', interp_method = "conserve_order1" )

      id_conv_snow3d= register_diag_field ( mod_name, &
                    'conv_snow3d', axes(half), Time, &
                     'Snow fall rate from convection -3D',   &
                      'kg(h2o)/m2/s', interp_method = "conserve_order1" )

!----------------------------------------------------------------------
!    tendencies of cloud tracers resulting from convection.
!----------------------------------------------------------------------
      if (doing_prog_clouds ) then

        id_qldt_conv = register_diag_field ( mod_name, &
                       'qldt_conv', axes(1:3), Time, &
                           'Liquid water tendency from convection',  &
                               'kg/kg/s', missing_value=missing_value  )

        if (do_liq_num) then
          id_qndt_conv = register_diag_field ( mod_name, &
                          'qndt_conv', axes(1:3), Time, &
                            'Liquid drop tendency from convection',  &
                                 '#/kg/s', missing_value=missing_value)
        endif

        id_qidt_conv = register_diag_field ( mod_name, &
                         'qidt_conv', axes(1:3), Time, &
                            'Ice water tendency from convection',   &
                                'kg/kg/s', missing_value=missing_value )

        id_qadt_conv = register_diag_field ( mod_name, &
                         'qadt_conv', axes(1:3), Time, &
                           'Cloud fraction tendency from convection',  &
                              '1/sec', missing_value=missing_value )

        id_ql_conv_col = register_diag_field ( mod_name, &
                          'ql_conv_col', axes(1:2), Time, &
                           'Liquid water path tendency from convection',  &
                                                              'kg/m2/s' )
   
        if (do_liq_num) then
          id_qn_conv_col = register_diag_field ( mod_name, &
                            'qn_conv_col', axes(1:2), Time, &
                               'Liquid drp tendency from convection',  &
                                                               'kg/m2/s' )
        endif
 
        id_qi_conv_col = register_diag_field ( mod_name, &
                           'qi_conv_col', axes(1:2), Time, &
                            'Ice water path tendency from convection',  &
                                                              'kg/m2/s' )
   
        id_qa_conv_col = register_diag_field ( mod_name, &
                           'qa_conv_col', axes(1:2), Time, &
                             'Cloud mass tendency from convection',   &
                                                               'kg/m2/s' )
      
        if (do_ice_num) then
          id_qnidt_conv = register_diag_field ( mod_name, &
                            'qnidt_conv', axes(1:3), Time, &
                              'Ice number tendency from convection',   &
                                  '#/kg/s', missing_value=missing_value )

          id_qni_conv_col = register_diag_field ( mod_name, &
                              'qni_conv_col', axes(1:2), Time, &
                               'Ice number tendency from convection',   &
                                                               'kg/m2/s' )
        endif
      endif ! (doing_prog_clouds)

!-----------------------------------------------------------------------
!    diagnostics for cloud base and cloud top.
!-----------------------------------------------------------------------
      id_conv_cld_base = register_diag_field ( mod_name, &
                            'conv_cld_base', axes(1:2), Time, &
                               'pressure at convective cloud base',  &
                                  'Pa', mask_variant = .true., &
                                        missing_value=missing_value )

      id_ccb = register_cmip_diag_field_2d ( mod_name, 'ccb', Time, &
                  'Air Pressure at Convective Cloud Base', 'Pa', &
                        standard_name =    &
                               'air_pressure_at_convective_cloud_base', &
                                                   mask_variant = .true. )

      id_conv_cld_top = register_diag_field ( mod_name, &
                          'conv_cld_top', axes(1:2), Time, &
                           'pressure at convective cloud top',   'Pa', &
                               mask_variant = .true., &
                                     missing_value=missing_value )

      id_cct = register_cmip_diag_field_2d ( mod_name, 'cct', Time, &
                 'Air Pressure at Convective Cloud Top', 'Pa', &
                      standard_name =   &
                              'air_pressure_at_convective_cloud_top', &
                                                  mask_variant = .true. )

!-----------------------------------------------------------------------
!    convective mass flux diagnostics.
!-----------------------------------------------------------------------
      id_mc_full = register_diag_field ( mod_name, &
                      'mc_full', axes(1:3), Time, &
                         'Net Mass Flux from convection',   'kg/m2/s', &
                                           missing_value=missing_value )

      id_mc_half = register_diag_field ( mod_name, &
                     'mc_half', axes(half), Time, &
                       'Net Mass Flux from convection on half levs',   &
                              'kg/m2/s', missing_value=missing_value )

      ID_mc = register_cmip_diag_field_3d ( mod_name, 'mc', Time, &
                    'Convective Mass Flux',   'kg m-2 s-1', &
                        standard_name=  &
                         'atmosphere_net_upward_convective_mass_flux', &
                           interp_method = "conserve_order1", axis="half" )
   
      id_mc_conv_up = register_diag_field ( mod_name, &
                        'mc_conv_up', axes(1:3), Time, &
                           'Upward Mass Flux from convection', 'kg/m2/s', &
                                            missing_value=missing_value )

!---------------------------------------------------------------------
!    register diagnostics for lightning NOx.
!---------------------------------------------------------------------
      if (get_tracer_index(MODEL_ATMOS,'no') > 0) then
        id_prod_no = register_diag_field ( 'tracers', &
                                         'hook_no', axes(1:3), Time, &
                                               'hook_no',   'molec/cm3/s')
        ID_emilnox_area = register_cmip_diag_field_3d ( mod_name,  &
                        'emilnox_area', Time, &
           'Layer-integrated Lightning Production of NOx', 'mol m-2 s-1', &
             standard_name=   &
              'tendency_of_atmosphere_moles_of_nox_expressed_as_nitrogen')
      end if

!-------------------------------------------------------------------------
!    register diagnostics specific to the Betts-Miller experiments.
!-------------------------------------------------------------------------
      if ( any((/do_bm, do_bmmass, do_bmomp/)) ) then
        id_qref = register_diag_field ( mod_name, &
                      'qref', axes(1:3), Time, &
                       'Adjustment reference specific humidity profile', &
                                    'kg/kg',  missing_value=missing_value)

        id_tref = register_diag_field ( mod_name, &
                      'tref', axes(1:3), Time, &
                         'Adjustment reference temperature profile', &
                                'K',  missing_value=missing_value )

        id_bmflag = register_diag_field (mod_name, &
                       'bmflag', axes(1:2), Time, &
                         'Betts-Miller flag', &
                            'no units', missing_value=missing_value)

        id_klzbs  = register_diag_field  (mod_name, &
                        'klzbs', axes(1:2), Time, &
                           'klzb', &
                             'no units', missing_value=missing_value  )

      endif

      if (do_bm ) then
        id_invtaubmt  = register_diag_field  (mod_name, &
                            'invtaubmt', axes(1:2), Time, &
                              'Inverse temperature relaxation time', &
                                       '1/s', missing_value=missing_value )

        id_invtaubmq = register_diag_field  (mod_name, &
                          'invtaubmq', axes(1:2), Time, &
                            'Inverse humidity relaxation time', &
                                     '1/s', missing_value=missing_value )
      end if 

      if (do_bmmass) then
        id_massflux = register_diag_field (mod_name, &
                        'massflux', axes(1:3), Time, &
                           'Massflux implied by temperature adjustment', &
                                   'm/s', missing_value=missing_value )
      end if  

!-------------------------------------------------------------------------
!    register diagnostics associated with CAPE / CIN calculations.
!-------------------------------------------------------------------------
      id_cape = register_diag_field ( mod_name, &
                    'cape', axes(1:2), Time, &
                      'Convectively available potential energy', 'J/Kg')
      
      id_cin = register_diag_field ( mod_name, &
                    'cin', axes(1:2), Time, 'Convective inhibition','J/Kg')

      id_tp = register_diag_field ( mod_name, &
              'tp', axes(1:3), Time, 'Temperature of lifted parcel', 'K')

      id_rp = register_diag_field ( mod_name, &
              'rp', axes(1:3), Time, 'Humidity of lifted parcel', 'kg/kg')

      id_lcl = register_diag_field ( mod_name, &
               'klcl', axes(1:2), Time, 'Index of LCL', 'none')

      id_lfc = register_diag_field ( mod_name, &
               'klfc', axes(1:2), Time, 'Index of LFC', 'none')

      id_lzb = register_diag_field ( mod_name, &
               'klzb', axes(1:2), Time, 'Index of LZB', 'none') 

!------------------------------------------------------------------------
!    register diagnostics specific to the ras parameterization.
!------------------------------------------------------------------------
      if (do_ras) then
        id_ras_precip = register_diag_field ( mod_name, &
                          'ras_precip', axes(1:2), Time, &
                            'Precipitation rate from ras ', 'kg/m2/s', &
                                 interp_method = "conserve_order1" )

        id_ras_freq = register_diag_field ( mod_name, &
                        'ras_freq', axes(1:2), Time, &
                          'frequency of precip from ras ', 'number' , &
                             missing_value = missing_value, &
                                  interp_method = "conserve_order1" )
      endif

!------------------------------------------------------------------------
!    register diagnostics specific to the donner parameterization.
!------------------------------------------------------------------------
      if (do_donner_deep) then
        id_don_precip = register_diag_field ( mod_name, &
                        'don_precip', axes(1:2), Time, &
                          'Precipitation rate from donner ', 'kg/m2/s', & 
                                        interp_method = "conserve_order1")

        id_don_freq = register_diag_field ( mod_name, &
                         'don_freq', axes(1:2), Time, &
                          'frequency of precip from donner ', 'number', &
                               missing_value = missing_value, &
                                      interp_method = "conserve_order1"  )

        id_enth_donner_col2 =   &
                      register_diag_field ( mod_name, &
                         'enth_donner_col2', axes(1:2), Time, &
                            'column enthalpy tendency from Donner liq&
                                                      & precip','W/m2' )
 
        id_enth_donner_col3 =   &
                      register_diag_field ( mod_name, &
                        'enth_donner_col3', axes(1:2), Time, &
                           'Column enthalpy tendency from Donner &
                                                  &frzn precip','W/m2' )
 
        id_enth_donner_col4 =   &
                      register_diag_field ( mod_name, &
                         'enth_donner_col4', axes(1:2), Time, &
                            'Atmospheric column enthalpy tendency from&
                                           & Donner convection', 'W/m2' )
 
        id_enth_donner_col5 =    &
                      register_diag_field ( mod_name, &
                         'enth_donner_col5', axes(1:2), Time, &
                              'Column enthalpy tendency due to condensate&
                                       & xfer from Donner to lsc','W/m2' )

        id_enth_donner_col6 =   &
                      register_diag_field ( mod_name, &
                          'enth_donner_col6', axes(1:2), Time, &
                            'Column enthalpy tendency from donner &
                              &moisture  conservation  adjustment','W/m2' )
 
        id_enth_donner_col7 =    &
                      register_diag_field ( mod_name, &
                          'enth_donner_col7', axes(1:2), Time, &
                             'Precip adjustment needed to balance donner&
                                   & moisture  adjustment','kg(h2o)/m2/s' )

        id_enth_donner_col =    &
                      register_diag_field ( mod_name, &
                         'enth_donner_col', axes(1:2), Time, &
                             'Column enthalpy imbalance from Donner &
                                                    &convection','W/m2' )

        id_wat_donner_col =    &
                     register_diag_field ( mod_name, &
                        'wat_donner_col', axes(1:2), Time, &
                            'Column total water tendency from Donner&
                                          & convection','kg(h2o)/m2/s' )
  
        id_enth_mca_donner_col =   &
                     register_diag_field ( mod_name, &
                            'enth_mca_donner_col', axes(1:2), Time, &
                                 'Column enthalpy imbalance from Donner&
                                                 & MCA convection','W/m2' )

        id_wat_mca_donner_col =   &
                     register_diag_field ( mod_name, &
                          'wat_mca_donner_col', axes(1:2), Time, &
                                'Column total water imbalance from Donner&
                                        & MCA convection', 'kg(h2o)/m2/s' )

        id_scale_donner =    &
                     register_diag_field ( mod_name, &
                       'scale_donner', axes(1:2), Time, &
                       'Scaling factor applied to donner convection&
                                                      & tendencies','1' )

        id_scale_donner_REV =   &
                     register_diag_field ( mod_name, &
                        'scale_donner_REV', axes(1:2), Time, &
                          ' Revised scaling factor for donner convection&
                                                        & tendencies','1' )

        id_tdt_deep_donner=    &
                     register_diag_field ( mod_name, &
                         'tdt_deep_donner', axes(1:3), Time, &
                              ' heating rate - deep portion',   &
                                  'deg K/s', missing_value=missing_value )

        id_qdt_deep_donner =   &
                     register_diag_field ( mod_name, &
                          'qdt_deep_donner', axes(1:3), Time, &
                            ' moistening rate - deep portion', 'kg/kg/s',&
                                            missing_value=missing_value  )

        id_qadt_deep_donner =   &
                       register_diag_field ( mod_name, &
                         'qadt_deep_donner', axes(1:3), Time, &
                            ' cloud amount tendency - deep portion',  &
                                      '1/s', missing_value=missing_value )

        id_qldt_deep_donner =   &
                       register_diag_field ( mod_name, &
                          'qldt_deep_donner', axes(1:3), Time, &
                              ' cloud liquid tendency - deep portion',  &
                                   'kg/kg/s', missing_value=missing_value)

        id_qidt_deep_donner =   &
                       register_diag_field ( mod_name, &
                           'qidt_deep_donner', axes(1:3), Time, &
                              ' ice water tendency - deep portion',  &
                                   'kg/kg/s', missing_value=missing_value)
        if (do_liq_num) &
          id_qndt_deep_donner =  &
                     register_diag_field ( mod_name, &
                        'qndt_deep_donner', axes(1:3), Time, &
                            'deep convection cloud drop tendency',  &
                                '#/kg/s', missing_value=missing_value )

        if (do_ice_num) &
          id_qnidt_deep_donner =  &
                    register_diag_field ( mod_name, &
                           'qnidt_deep_donner', axes(1:3), Time, &
                              ' ice number tendency - deep portion', &
                                '#/kg/s', missing_value=missing_value )

        id_tdt_mca_donner =   &
                    register_diag_field ( mod_name, &
                       'tdt_mca_donner', axes(1:3), Time, &
                          ' heating rate - mca  portion', 'deg K/s', &
                                            missing_value=missing_value )

        id_qdt_mca_donner =    &
                     register_diag_field ( mod_name, &
                         'qdt_mca_donner', axes(1:3), Time, &
                            ' moistening rate - mca  portion', 'kg/kg/s', &
                                             missing_value=missing_value )

        id_prec_deep_donner =   &
                     register_diag_field ( mod_name, &
                       'prc_deep_donner', axes(1:2), Time, &
                         ' total precip rate - deep portion',  &
                             'kg/m2/s', missing_value=missing_value, &
                                        interp_method = "conserve_order1")

        id_precret_deep_donner =  &
                     register_diag_field ( mod_name, &
                         'prc_ret_deep_donner', axes(1:2), Time, &
                           ' precip_returned - per timestep',   &
                                'kg/m2/timestep', &
                                   missing_value=missing_value, &
                                       interp_method = "conserve_order1" )

        id_prec1_deep_donner =   &
                     register_diag_field ( mod_name, &
                        'prc1_deep_donner', axes(1:2), Time, &
                          ' change in precip for conservation&
                              & in donner', 'kg/m2/s ', &
                                 missing_value=missing_value,  &
                                    mask_variant = .true., &
                                       interp_method = "conserve_order1")

        id_prec_mca_donner =   &
                      register_diag_field ( mod_name, &
                        'prc_mca_donner', axes(1:2), Time, &
                          ' total precip rate - mca  portion',  &
                             'kg/m2/s', missing_value=missing_value, &
                                        interp_method = "conserve_order1" )

        id_snow_deep_donner =    &
                    register_diag_field ( mod_name, &
                        'snow_deep_donner', axes(1:2), Time, &
                          ' frozen precip rate - deep portion',   &
                               'kg/m2/s', missing_value=missing_value, &
                                      interp_method = "conserve_order1" )

        id_snow_mca_donner =    &
                      register_diag_field ( mod_name, &
                        'snow_mca_donner', axes(1:2), Time, &
                          ' frozen precip rate -  mca portion',  &
                             'kg/m2/s', missing_value=missing_value, &
                                    interp_method = "conserve_order1"  )

        id_mc_donner =   &
                 register_diag_field ( mod_name, &
                     'mc_donner', axes(1:3), Time, &
                         'Net Mass Flux from donner',   'kg/m2/s', &
                                           missing_value=missing_value )

        id_mc_donner_half =   &
                 register_diag_field ( mod_name, &
                        'mc_donner_half', axes(half), Time, &
                            'Net Mass Flux from donner at half levs',  &
                                'kg/m2/s', missing_value=missing_value )

        id_m_cdet_donner =   &
                   register_diag_field ( mod_name, &
                     'm_cdet_donner', axes(1:3), Time, &
                        'Detrained Cell Mass Flux from donner',  &
                               'kg/m2/s', missing_value=missing_value )

        id_m_cellup =   &
                 register_diag_field ( mod_name, &
                     'm_cellup', axes(half), Time, &
                        'Upward Cell Mass Flux from donner', 'kg/m2/s', &
                                              missing_value=missing_value )

        id_cell_cld_frac =   &
                  register_diag_field ( mod_name, &
                      'cell_cld_frac', axes(1:3), Time, & 
                           'cell cloud fraction from donner',   '', &
                                         missing_value=missing_value )

        id_meso_cld_frac =   &
                 register_diag_field ( mod_name, &
                     'meso_cld_frac', axes(1:3), Time, & 
                          'meso-scale cloud fraction from donner',   '', &
                                             missing_value=missing_value )

        id_donner_humidity_area =   &
                  register_diag_field ( mod_name, &
                           'donner_humidity_area', axes(1:3), Time,&
                                  'donner humidity area',  '', &
                                           missing_value=missing_value  )

        if (do_donner_conservation_checks) then

          id_enthint =    &
                register_diag_field (mod_name, 'enthint_don', axes(1:2), &
                  Time, 'atmospheric column enthalpy change from donner', &
                                      'W/m2', missing_value=missing_value)

          id_lcondensint =    &
                 register_diag_field    &
                        (mod_name, 'lcondensint_don', axes(1:2), Time, &
                             'enthalpy transferred by condensate from &
                                     &donner to lscale', 'W/m2',  &
                                            missing_value=missing_value)

          id_lprcp =   &
                 register_diag_field    &
                     (mod_name, 'lprcpint_don', axes(1:2), Time,  &
                          'enthalpy removed by donner precip', 'W/m2',   &
                                              missing_value=missing_value)

          id_vertmotion =   &
                register_diag_field    &
                    (mod_name, 'vertmotion_don', axes(1:2), Time,  &
                      'enthalpy change due to cell and meso motion &
                          &in donner', 'W/m2',  &
                                             missing_value=missing_value)

          id_enthdiffint =    &
                 register_diag_field    &
                     (mod_name, 'enthdiffint_don', axes(1:2),   &
                        Time, 'enthalpy  imbalance due to donner',  &
                                    'W/m2', missing_value=missing_value)

          id_vaporint =    &
                    register_diag_field    &
                           (mod_name, 'vaporint_don', axes(1:2),   &
                                 Time, 'column water vapor change',   &
                                     'kg(h2o)/m2/s',   &
                                            missing_value=missing_value)

          id_max_enthalpy_imbal_don =   &
                    register_diag_field    &
                         (mod_name, 'max_enth_imbal_don', axes(1:2),&
                           Time, 'max enthalpy  imbalance from donner',  &
                                    'W/m**2', missing_value=missing_value)

          id_max_water_imbal_don =   &
                     register_diag_field    &
                         (mod_name, 'max_water_imbal_don', &
                             axes(1:2), Time, 'max water imbalance&
                                & from donner', 'kg(h2o)/m2/s', &
                                             missing_value=missing_value)

          id_condensint =   &
                    register_diag_field    &
                       (mod_name, 'condensint_don', axes(1:2), Time,  &
                          'column condensate exported from donner&
                              & to lscale', 'kg(h2o)/m2/s',  &
                                      missing_value=missing_value )

          id_precipint =   &
                     register_diag_field    &
                         (mod_name, 'precipint_don', axes(1:2),   &
                            Time, 'column precip from donner',  &
                              'kg(h2o)/m2/s', missing_value=missing_value)

          id_diffint=    &
                   register_diag_field    &
                      (mod_name, 'diffint_don', axes(1:2),   &
                         Time, 'water imbalance due to donner', &
                             'kg(h2o)/m2/s', missing_value=missing_value)

        endif
      endif

!------------------------------------------------------------------------
!    register diagnostics specific to the uw parameterization.
!------------------------------------------------------------------------
      if (do_uw_conv) then
        id_uw_precip = register_diag_field ( mod_name, &
                       'uw_precip', axes(1:2), Time, &
                       'Precipitation rate from uw shallow',  'kg/m2/s', &
                       interp_method = "conserve_order1" )

        id_uw_snow = register_diag_field ( mod_name, &
                     'uw_snow', axes(1:2), Time, &
                     'Snow rate from uw shallow',       'kg/m2/s' , &
                     interp_method = "conserve_order1" )

        id_uw_freq = register_diag_field ( mod_name, &
                     'uw_freq', axes(1:2), Time, &
                     'frequency of precip from uw shallow ',  'number' , &
                           missing_value = missing_value,   &
                                   interp_method = "conserve_order1"  )

        id_enth_uw_col = register_diag_field ( mod_name, &
                         'enth_uw_col', axes(1:2), Time, &
                         'Column enthalpy tendency from UW convection', &
                         'W/m2' )
 
        id_wat_uw_col = register_diag_field ( mod_name, &
                        'wat_uw_col', axes(1:2), Time, &
                        'Column total water tendency from UW convection',&
                        'kg(h2o)/m2/s' )

        id_scale_uw = register_diag_field ( mod_name, &
                      'scale_uw', axes(1:2), Time, &
                      'Scaling factor applied to UW convection&
                      & tendencies','1' )
          
        id_tdt_uw = register_diag_field ( mod_name, &
                    'tdt_uw', axes(1:3), Time, &
                    'UW convection heating rate', 'deg K/s', &
                    missing_value=missing_value               )

        id_qdt_uw = register_diag_field ( mod_name, &
                    'qdt_uw', axes(1:3), Time, &
                    'UW convection moistening rate', 'kg/kg/s', &
                    missing_value=missing_value               )

        id_qadt_uw = register_diag_field ( mod_name, &
                     'qadt_uw', axes(1:3), Time, &
                     'UW convection cloud amount tendency', '1/s', &
                     missing_value=missing_value               )

        id_qldt_uw = register_diag_field ( mod_name, &
                     'qldt_uw', axes(1:3), Time, &
                     'UW convection cloud liquid tendency', 'kg/kg/s', &
                     missing_value=missing_value               )

        id_qidt_uw = register_diag_field ( mod_name, &
                     'qidt_uw', axes(1:3), Time, &
                     'UW convection ice water tendency', 'kg/kg/s', &
                     missing_value=missing_value               )

        if (do_liq_num) &
          id_qndt_uw = register_diag_field ( mod_name, &
                       'qndt_uw', axes(1:3), Time, &
                       'UW convection cloud drop tendency', '#/kg/s', &
                       missing_value=missing_value               )

        if (do_ice_num) &
          id_qnidt_uw = register_diag_field ( mod_name, &
                        'qnidt_uw', axes(1:3), Time, &
                        'UW convection ice number tendency', '#/kg/s', &
                        missing_value=missing_value               )

      endif

!----------------------------------------------------------------------
!    dry adjustment diagnostic.
!----------------------------------------------------------------------
      if (do_dryadj) then
        id_tdt_dadj = register_diag_field ( mod_name, &
                    'tdt_dadj', axes(1:3), Time, &
                    'Temperature tendency from dry conv adj', 'deg_K/s',  &
                    missing_value=missing_value               )
      endif

!---------------------------------------------------------------------
!    allocate and initialize arrays to hold the diagnostic ids for each 
!    active tracer. diagnostics for tendency due to convection, 
!    column tendency due to convection, the tracer amount and tracer 
!    column amount are available.
!---------------------------------------------------------------------
      allocate (id_tracerdt_conv     (num_prog_tracers))
      allocate (id_tracerdt_conv_col (num_prog_tracers))
      allocate (id_conv_tracer       (num_prog_tracers))
      allocate (id_conv_tracer_col   (num_prog_tracers))

      id_tracerdt_conv = NO_TRACER
      id_tracerdt_conv_col = NO_TRACER
      id_conv_tracer = NO_TRACER
      id_conv_tracer_col = NO_TRACER
 
!------------------------------------------------------------------------
!    define the diagnostics names that are requested and register the
!    diagnostics for those tracers that were specified to be affected
!    by a convection scheme.
!------------------------------------------------------------------------
      do n = 1,num_prog_tracers
        call get_tracer_names (MODEL_ATMOS, n, name = tracer_name,  &
                                                  units = tracer_units)
        if (Control%tracers_in_donner(n) .or. &
            Control%tracers_in_ras(n)      .or.  &
            Control%tracers_in_mca(n)      .or.  &
            Control%tracers_in_uw(n)) then
          diaglname = trim(tracer_name)//  &
                        ' total tendency from moist convection'
          id_tracerdt_conv(n) =    &
                         register_diag_field ( mod_name, &
                         TRIM(tracer_name)//'dt_conv',  &
                         axes(1:3), Time, trim(diaglname), &
                         TRIM(tracer_units)//'/s',  &
                         missing_value=missing_value)

          diaglname = trim(tracer_name)//  &
                       ' total path tendency from moist convection'
          id_tracerdt_conv_col(n) =  &
                         register_diag_field ( mod_name, &
                         TRIM(tracer_name)//'dt_conv_col', &
                         axes(1:2), Time, trim(diaglname), &
                         TRIM(tracer_units)//'*(kg/m2)/s',   &
                         missing_value=missing_value)
        endif
 
!----------------------------------------------------------------------
!    output the distribution and column values of any tracer for which
!    they are requested, even if not transported by convection.
!----------------------------------------------------------------------
        diaglname = trim(tracer_name)

!---------------------------------------------------------------------
!    RSH:
!    temporary get-around for the fact that 'cl' may be both a tracer 
!    variable (full chemistry) and a CMIP6 cloud diagnostic variable 
!    in module 'moist', and so they need to be registered differently. 
!    In the future, all the tracers should be registered under mod_name2,
!    after existing scripts / experiments are replaced. 
!---------------------------------------------------------------------
        if (trim(diaglname) == 'cl') then
          id_conv_tracer(n) =    &
                        register_diag_field ( mod_name2,    &
                        TRIM(tracer_name),  &
                        axes(1:3), Time, trim(diaglname), &
                        TRIM(tracer_units)      ,  &
                        missing_value=missing_value)
        else
          id_conv_tracer(n) =    &
                        register_diag_field ( mod_name,    &
                        TRIM(tracer_name),  &
                        axes(1:3), Time, trim(diaglname), &
                        TRIM(tracer_units)      ,  &
                        missing_value=missing_value)
        endif
        diaglname =  ' column integrated' // trim(tracer_name)
        id_conv_tracer_col(n) =  &
                        register_diag_field ( mod_name, &
                        TRIM(tracer_name)//'_col', &
                        axes(1:2), Time, trim(diaglname), &
                        TRIM(tracer_units)      ,   &
                        missing_value=missing_value)
      end do

!------------------------------------------------------------------
!    register the diagnostics which will report the tendencies due to
!    mca component of donner convection.
!------------------------------------------------------------------
      if (do_donner_mca) then
        allocate (id_tracerdt_mcadon  (Control%num_donner_tracers))
        allocate (id_tracerdt_mcadon_col(Control%num_donner_tracers))
 
        nn = 1
        do n = 1,num_prog_tracers
          call get_tracer_names (MODEL_ATMOS, n, name = tracer_name,  &
                                                    units = tracer_units)
          if (Control%tracers_in_donner(n) ) then
            diaglname = trim(tracer_name)//  &
                       ' tendency from donner-mca'
            id_tracerdt_mcadon(nn) =    &
                         register_diag_field ( mod_name, &
                         TRIM(tracer_name)//'_donmca',  &
                         axes(1:3), Time, trim(diaglname), &
                         TRIM(tracer_units)//'/s',  &
                        missing_value=missing_value)

            diaglname = trim(tracer_name)//  &
                       ' total path tendency from donner-mca'
            id_tracerdt_mcadon_col(nn) =  &
                        register_diag_field ( mod_name, &
                        TRIM(tracer_name)//'_donmca_col', &
                        axes(1:2), Time, trim(diaglname), &
                          TRIM(tracer_units)//'*(kg/m2)/s',   &
                        missing_value=missing_value)
            nn = nn + 1
          endif
        end do
      endif


!---------------------------------------------------------------------


end subroutine diag_field_init




!*******************************************************************
!
!                     PRIVATE DRIVER-CALLED SUBROUTINES,
!                       NON-CONVECTION-SCHEME SPECIFIC
!
!*******************************************************************


!#######################################################################

subroutine convection_driver_alloc (ix, jx, kx, Conv_results)

!---------------------------------------------------------------------
!    subroutine convection_driver_alloc allocates and initializes
!    variables that are calculated in this module and transferred
!    between convective parameterizations and / or to the diagnostics 
!    routine for output.
!---------------------------------------------------------------------

integer,                 intent(in)      :: ix, jx, kx
type(conv_results_type), intent(inout)   :: Conv_results

!--------------------------------------------------------------------
!      ix, jx, kx      dimensions of physics window
!      Conv_results    conv_results_type variable containing local 
!                      variables used in multiple convective 
!                      parameterizations and for diagnostic output
!--------------------------------------------------------------------

!--------------------------------------------------------------------
!    allocate and initialize arrays which transfer data between individual
!    parameterizations within an implementation.
!--------------------------------------------------------------------

      allocate (Conv_results%conv_calc_completed  (ix, jx))
      allocate (Conv_results%available_cf_for_uw  (ix, jx, kx))
      Conv_results%conv_calc_completed = .false.
      Conv_results%available_cf_for_uw = 1.0

!------------------------------------------------------------------------
!    allocate and initialize the massflux-related components of the 
!    conv_results_type variable Conv_results.
!------------------------------------------------------------------------
      allocate (Conv_results%ras_mflux(ix, jx, kx+1))   ! old variable mc
      allocate (Conv_results%ras_det_mflux(ix, jx, kx)) ! old variable det0
      if (do_donner_deep) then
        allocate (Conv_results%donner_mflux(ix, jx, kx+1)) ! m_cellup
        allocate (Conv_results%donner_det_mflux(ix, jx, kx)) !m_cdet_donner
      endif
      allocate (Conv_results%uw_mflux(ix, jx, kx+1))  ! cmf
      Conv_results%ras_mflux = 0.
      Conv_results%ras_det_mflux = 0.
      if (do_donner_deep) then
        Conv_results%donner_mflux = 0.
        Conv_results%donner_det_mflux = 0.
      endif
      Conv_results%uw_mflux = 0.

      allocate (Conv_results%mc_donner       (ix, jx, kx))  
      allocate (Conv_results%mc_donner_up    (ix, jx, kx)) 
      allocate (Conv_results%mc_donner_half  (ix, jx, kx+1))  
      Conv_results%mc_donner = 0.
      Conv_results%mc_donner_up = 0.
      Conv_results%mc_donner_half = 0.

!------------------------------------------------------------------------
!    allocate the components of the conv_results_type variable Conv_results
!    which depend on the results of the convective implementation, not each
!    convective parameterization included within it.
!------------------------------------------------------------------------
      allocate (Conv_results%cldtop        (ix, jx)) 
      allocate (Conv_results%cldbot        (ix, jx))
      allocate (Conv_results%prod_no       (ix, jx, kx))
      Conv_results%cldtop = 0
      Conv_results%cldbot = 0
      Conv_results%prod_no = 0.

!----------------------------------------------------------------------


end subroutine convection_driver_alloc



!######################################################################

subroutine define_total_convective_output    &
              (is, js, nt, C2ls_mp, Conv_results, Input_mp, Output_mp,   &
                                                             Phys_mp_exch)

!----------------------------------------------------------------------
!    subroutine define_total_convective_output: a) defines total cloud 
!    mass flux, b) defines cloud base and cloud top, c) defines lightning
!    source of nox, d) defines convective gustiness, e) sets flag 
!    indicating columns with convection, f) updates the Input_mp%tracer 
!    field with the changes produced in this module, and g) updates the 
!    tin and rdt fields with the uw tendencies if they have not already 
!    been so updated. Updating fields at this point only occurs when 
!    legacy warsaw results are desired; otherwise the updates would have 
!    been done at the more appropriate earlier time in the integration.
!----------------------------------------------------------------------

!-----------------------------------------------------------------------
integer,                  intent(in)    :: is, js, nt
type(mp_conv2ls_type),    intent(inout) :: C2ls_mp
type(conv_results_type),  intent(inout) :: Conv_results
type(mp_input_type),      intent(inout) :: Input_mp
type(mp_output_type),     intent(inout) :: Output_mp
type(phys_mp_exch_type),  intent(inout) :: Phys_mp_exch
!-----------------------------------------------------------------------

!----------------------------------------------------------------------
!    is, js     starting i,j physics window indices
!    nt         number of prognostic tracers
!    C2ls_mp    derived type used to transfer data from 
!               convection_driver to lscloud_driver via moist_processes.
!    Conv_results  
!               conv_results_type variable containing local variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Phys_mp_exch
!               derived type used to transfer data between physics_driver
!               and convection_driver via moist_processes
!----------------------------------------------------------------------

      real, parameter :: boltz = 1.38044e-16
      integer :: i, j, k, n
      integer :: ix, jx, kx

!---------------------------------------------------------------------
!       boltz           boltzmann constant
!       i, j, k, n      do-loop indices
!       ix, jx, kx      physics window dimensions
!---------------------------------------------------------------------

!------------------------------------------------------------------------
!    define array dimensions.
!------------------------------------------------------------------------
      ix = size(Input_mp%tin,1)
      jx = size(Input_mp%tin,2)
      kx = size (Input_mp%t, 3)

!------------------------------------------------------------------------
!    define total convective mass flux from all sources, at both full
!    levels and at half levels.
!------------------------------------------------------------------------
      C2ls_mp%mc_full(:,:,1)=0.; 
      C2ls_mp%mc_half(:,:,1)=0.; 
      do k=2,kx   
        C2ls_mp%mc_full(:,:,k) = 0.5*(Conv_results%ras_mflux(:,:,k) +   &
                                      Conv_results%ras_mflux(:,:,k+1)) + &
                                 0.5*(Conv_results%uw_mflux(:,:,k)+   &
                                      Conv_results%uw_mflux(:,:,k-1)) +   &
                                      Conv_results%mc_donner(:,:,k)
      end do
      do k=2,kx+1   
        C2ls_mp%mc_half(:,:,k) = Conv_results%ras_mflux(:,:,k) +    &
                                 Conv_results%uw_mflux(:,:,k-1)+   &
                                 Conv_results%mc_donner_half(:,:,k)
      end do

!------------------------------------------------------------------------ 
!    define convective cloud base and cloud top. these are needed if 
!    diagnostics defining the temporal and spatial location of convection 
!    are desired or if tracer "no" is present, so that the nox tendency 
!    due to lightning may be calculated.
!------------------------------------------------------------------------ 
      if (get_tracer_index(MODEL_ATMOS,'no') .ne. NO_TRACER &
           .or. id_conv_freq > 0 &
           .or. id_ci > 0 &
           .or. id_conv_cld_base > 0 &
           .or. id_ccb           > 0 &
           .or. id_cct           > 0 &
           .or. id_conv_cld_top > 0 ) then

        do j=1,jx
          do i=1,ix
            do k=1,kx
              if (C2ls_mp%mc_full(i,j,k) /= 0.0 ) then
                Conv_results%cldtop(i,j) = k
                exit
              endif
            enddo
            do k = size(Input_mp%r,3),1,-1
              if (C2ls_mp%mc_full(i,j,k) /= 0.0 ) then
                Conv_results%cldbot(i,j) = k
                exit
              endif
            enddo
          enddo
        enddo
      end if

!-----------------------------------------------------------------------
!    calculate NOx tendency from lightning and add it to the tendency
!    field.  
!-----------------------------------------------------------------------
      if ( get_tracer_index(MODEL_ATMOS,'no') .ne. NO_TRACER ) then
        call moz_hook       &
              (Conv_results%cldtop, Conv_results%cldbot, Input_mp%land, &
               Input_mp%zfull, Input_mp%zhalf, Input_mp%t,   &
               Conv_results%prod_no, Input_mp%area, Input_mp%lat,   &
               Time, is, js)

        Output_mp%rdt(:,:,:,get_tracer_index(MODEL_ATMOS,'no')) =  &
              Output_mp%rdt(:,:,:,get_tracer_index(MODEL_ATMOS,'no')) + &
                  Conv_results%prod_no*((boltz*Input_mp%t)/      &
                                                  (10. * Input_mp%pfull)) 
      endif

!-----------------------------------------------------------------------
!    calculate convective gustiness, if desired. two forms are available.
!-----------------------------------------------------------------------
      if (do_gust_cv) then
        where((Output_mp%precip) > 0.0)
          Output_mp%gust_cv = gustmax*   &
                    sqrt(Output_mp%precip/(gustconst + Output_mp%precip))
        end where
      end if

      if (do_gust_cv_new) then
        Output_mp%gust_cv = sqrt(Phys_mp_exch%cgust)
      end if

!---------------------------------------------------------------------
!    save a field indicating whether or not convection has occurred
!    within the column.
!---------------------------------------------------------------------
      where (Output_mp%precip > 0.) Output_mp%convect = .true.

!------------------------------------------------------------------------
!    update the current temp and rdt tendencies with the contributions 
!    obtained from uw transport (tin_tentative, rdt_tentative), if  
!    reproduce_AM4 was set true. otherwise these fields have 
!    already been updated, and the _tentative fields contain 0.0.
!------------------------------------------------------------------------
      Input_mp%tin = Input_mp%tin + Input_mp%tin_tentative
      Output_mp%rdt = Output_mp%rdt + Output_mp%rdt_tentative

!---------------------------------------------------------------------
!    update the input tracer arrays with the tendencies obtained in this
!    module.
!---------------------------------------------------------------------
      do n=1,nt                       
        if (.not. cloud_tracer(n)) then
          Input_mp%tracer(:,:,:,n) = Input_mp%tracer_orig(:,:,:,n) +   &
                 (Output_mp%rdt(:,:,:,n) - Output_mp%rdt_init(:,:,:,n))*dt
        endif
      end do

!------------------------------------------------------------------------


end subroutine define_total_convective_output



!######################################################################

subroutine convective_diagnostics    &
             (is, js, C2ls_mp, Conv_results, Input_mp, Tend_mp, Output_mp)

!-----------------------------------------------------------------------
!    subroutine convective_diagnostics outputs requested convective
!    diagnostics associated with the convective implementation rather than
!    any specific convective parameterization.
!-----------------------------------------------------------------------

integer,                     intent(in)    :: is, js
type(mp_conv2ls_type),       intent(inout) :: C2ls_mp
type(conv_results_type),     intent(inout) :: Conv_results
type(mp_input_type),         intent(inout) :: Input_mp
type(mp_tendency_type),      intent(inout) :: Tend_mp
type(mp_output_type),        intent(in)    :: Output_mp

!--------------------------------------------------------------------
!    is, js     starting i,j physics window indices
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Conv_results
!               conv_results_type variable containing local variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!--------------------------------------------------------------------

      real, dimension(size(Input_mp%t,1),size(Input_mp%t,2)) ::      &
                                                  temp_2d, freq_count
      logical, dimension(size(Input_mp%t,1),size(Input_mp%t,2)) ::      &
                                                               ltemp
      real, dimension(size(Input_mp%t,1),size(Input_mp%t,2), &
                           size(Input_mp%t,3)) ::      &
                                  temp_3d1, temp_3d2, uw_massflx_full
      integer :: i,j,k, n
      integer :: ix, jx, kx
      logical :: used

!--------------------------------------------------------------------
!      temp_2d            array used to hold diagnostic fields when
!                         they are sent for output
!      freq_count         array used to hold diagnostic field when sent
!                         for output
!      ltemp              logical used to define condition needed for
!                         several diagnostics
!      temp_3d1           temporary array used in computing diagnostics
!      temp_3d2           temporary array used in computing diagnostics
!      uw_massflx_full    uw massflux on full levels  [ kg/m2/s ]
!      i, j, k, n         do loop indices
!      ix, jx, kx         array spatial dimensions, size of physics window
!      used               logical used to indicate data has been received 
!                         by diag_manager_mod
!--------------------------------------------------------------------

!-------------------------------------------------------------------
!    define array dimensions.
!-------------------------------------------------------------------
      ix = size(Input_mp%r,1)
      jx = size(Input_mp%r,2)
      kx = size(Input_mp%r,3)

!-----------------------------------------------------------------------
!    output the NOx tendency from lightning.
!-----------------------------------------------------------------------
      if ( get_tracer_index(MODEL_ATMOS,'no') .ne. NO_TRACER ) then
        used = send_data(id_prod_no, Conv_results%prod_no, Time, is, js)
        used = send_cmip_data_3d (ID_emilnox_area, & ! convert molec/cm3/s to mol/m2/s
                                  Conv_results%prod_no*1.e6*(Input_mp%zhalf(:,:,1:kx)-Input_mp%zhalf(:,:,2:kx+1))/AVOGNO, &
                                  Time, is, js, 1, phalf=log(Input_mp%phalf))
      endif

!----------------------------------------------------------------------
!    output any requested convectively-transported tracer fields 
!    and / or their column sums before convective transport.
!----------------------------------------------------------------------
      do n=1, num_prog_tracers
        used = send_data (id_conv_tracer(n),   &
                           Input_mp%tracer_orig(:,:,:,n), Time, is, js, 1)
        if (id_conv_tracer_col(n) > 0)  &
          call column_diag(id_conv_tracer_col(n), is, js, Time, &
                       Input_mp%tracer_orig(:,:,:,n), 1.0, Input_mp%pmass) 
      end do

!---------------------------------------------------------------------
!    output diagnostics:
!    total cumulus mass flux on full levels,
!    total cumulus mass flux on half levels,
!    total cumulus mass flux on half levels (CMOR standard).
!---------------------------------------------------------------------
      used = send_data (id_mc_full, C2ls_mp%mc_full, Time, is, js, 1)
      used = send_data (id_mc_half, C2ls_mp%mc_half, Time, is, js, 1)
      used = send_cmip_data_3d (ID_mc, C2ls_mp%mc_half, Time, is, js, 1)

!---------------------------------------------------------------------
!    total convective updraft mass flux (uw + donner cell up + 
!    donner meso up) on full levels.
!---------------------------------------------------------------------
      if (id_mc_conv_up > 0 ) then
        do k=1,kx
          uw_massflx_full(:,:,k) = 0.5*(Conv_results%uw_mflux(:,:,k) + &
                                         Conv_results%uw_mflux(:,:,k+1))
        end do
        used = send_data (id_mc_conv_up, uw_massflx_full(:,:,:) + &
                      Conv_results%mc_donner_up(:,:,:), Time, is, js, 1 )
      endif

!------------------------------------------------------------------------
!    output diagnostics related to convective cloud base and cloud top.
!    both FMS-standard and CMOR-standard output variables are currently
!    present.
!------------------------------------------------------------------------
      if ( id_conv_cld_base > 0 ) then
        temp_2d = missing_value
        do j = 1,jx
          do i = 1,ix
            if ( Conv_results%cldbot(i,j) > 0 ) temp_2d(i,j) =    &
                              Input_mp%pfull(i,j,Conv_results%cldbot(i,j))
          end do
        end do
        used = send_data(id_conv_cld_base, temp_2d, Time, is_in=is,   &
                               js_in=js,  mask = Conv_results%cldbot > 0)
      end if

      if ( id_ccb > 0 ) then
        temp_2d = CMOR_MISSING_VALUE
        do j = 1,jx  
          do i = 1,ix
            if ( Conv_results%cldbot(i,j) > 0 ) temp_2d(i,j) =    &
                             Input_mp%pfull(i,j,Conv_results%cldbot(i,j))
          end do
        end do
        used = send_data(id_ccb, temp_2d, Time, is_in=is,   &
                                js_in=js,  mask = Conv_results%cldbot > 0)
      end if

      if ( id_conv_cld_top > 0 ) then
        temp_2d = missing_value
        do j = 1,jx
          do i = 1,ix
            if ( Conv_results%cldtop(i,j) > 0 ) temp_2d(i,j) =   &
                               Input_mp%pfull(i,j,Conv_results%cldtop(i,j))
          end do
        end do
        used = send_data(id_conv_cld_top, temp_2d, Time, is_in=is, &
                                js_in=js,  mask = Conv_results%cldtop > 0)
      end if

      if ( id_cct > 0 ) then
        temp_2d = CMOR_MISSING_VALUE
        do j = 1,jx
          do i = 1,ix
            if ( Conv_results%cldtop(i,j) > 0 ) temp_2d(i,j) =    &
                              Input_mp%pfull(i,j,Conv_results%cldtop(i,j))
          end do
        end do
        used = send_data(id_cct, temp_2d, Time, is_in=is, &
                               js_in=js,  mask = Conv_results%cldtop > 0)
      end if


!---------------------------------------------------------------------
!    temperature change due to dry and moist convection:
!---------------------------------------------------------------------
      used = send_data (id_tdt_conv, Tend_mp%ttnd_conv, Time, is, js, 1)
      if (query_cmip_diag_id(ID_tntc)) then
        used = send_cmip_data_3d (ID_tntc, Tend_mp%ttnd_conv, Time, is,  &
                                        js,1, phalf=log(Input_mp%phalf))
      endif

!---------------------------------------------------------------------
!    vapor specific humidity change due to convection:
!---------------------------------------------------------------------
      used = send_data (id_qdt_conv, Tend_mp%qtnd_conv, Time, is, js, 1)
      if (query_cmip_diag_id(ID_tnhusc)) then
        used = send_cmip_data_3d (ID_tnhusc, Tend_mp%qtnd_conv, Time,  &
                                   is, js, 1, phalf=log(Input_mp%phalf))
      endif

!---------------------------------------------------------------------
!    total precipitation due to convection (both FMS and CMOR standards):
!---------------------------------------------------------------------
      used = send_data (id_prec_conv, Output_mp%precip, Time, is, js)
      used = send_data (id_prc, Output_mp%precip, Time, is, js)
      if (id_prc_g > 0)  call buffer_global_diag     &
                          (id_prc_g, Output_mp%precip(:,:), Time, is, js)

!---------------------------------------------------------------------
!    frozen precipitation (snow) due to convection:
!---------------------------------------------------------------------
      used = send_data (id_snow_conv, Output_mp%fprec, Time, is, js)
      used = send_data (id_prsnc, Output_mp%fprec, Time, is, js)
!---------------------------------------------------------------------
!    liquid precipitation (rain) due to convection:
!---------------------------------------------------------------------
      used = send_data (id_prrc, Output_mp%lprec, Time, is, js)

!---------------------------------------------------------------------
!    convective frequency (both FMS and CMOR standards).
!---------------------------------------------------------------------
      if (id_conv_freq > 0 .or. id_ci > 0) then
        ltemp = Output_mp%precip > 0. .or. Conv_results%cldtop > 0
        where (ltemp)
          freq_count = 1.
        elsewhere
          freq_count = 0.
        end where
        if (id_conv_freq > 0) &
            used = send_data (id_conv_freq, freq_count, Time, is, js )
        if (id_ci > 0)     &
            used = send_data (id_ci, freq_count, Time, is, js )
      endif

!---------------------------------------------------------------------
!    surface wind gustiness due to convection:
!---------------------------------------------------------------------
      used = send_data (id_gust_conv, Output_mp%gust_cv, Time, is, js)

!---------------------------------------------------------------------
!    water vapor path tendency due to convection:
!---------------------------------------------------------------------
      if (id_q_conv_col > 0)   &
           call column_diag (id_q_conv_col, is, js, Time, &
                              Tend_mp%qtnd_conv, 1.0, Input_mp%pmass)
  
!---------------------------------------------------------------------
!    dry static energy tendency due to dry and moist convection:
!---------------------------------------------------------------------
      if (id_t_conv_col > 0)   &
            call column_diag (id_t_conv_col, is, js, Time, &
                               Tend_mp%ttnd_conv, CP_AIR, Input_mp%pmass)
   
!---------------------------------------------------------------------
!    define the total prognostic cloud liquid, ice, drop number, 
!    ice number and area tendencies due to convection.
!---------------------------------------------------------------------
      if (doing_prog_clouds) then
        Tend_mp%qldt_conv = Output_mp%rdt(:,:,:,nql) -  &
                                          Output_mp%rdt_init(:,:,:,nql)
        Tend_mp%qidt_conv = Output_mp%rdt(:,:,:,nqi) -   &
                                         Output_mp%rdt_init(:,:,:,nqi)
        if (do_liq_num) Tend_mp%qndt_conv =    &
                           Output_mp%rdt(:,:,:,nqn) -   &
                                       Output_mp%rdt_init(:,:,:,nqn)
        if (do_ice_num) Tend_mp%qnidt_conv =    &
                              Output_mp%rdt(:,:,:,nqni) -   &
                                      Output_mp%rdt_init(:,:,:,nqni)
        Tend_mp%qadt_conv = Output_mp%rdt(:,:,:,nqa) -    &
                                       Output_mp%rdt_init(:,:,:,nqa)

!---------------------------------------------------------------------
!    output diagnostics for cloud liquid tendency and liquid water path 
!    tendency due to convection.
!---------------------------------------------------------------------
        if (id_qldt_conv > 0 .or. id_ql_conv_col > 0) then
          used = send_data (id_qldt_conv, Tend_mp%qldt_conv,    &
                                                       Time, is, js, 1)
          if (id_ql_conv_col > 0)    &
                call column_diag (id_ql_conv_col, is, js, Time,   &
                                  Tend_mp%qldt_conv, 1.0, Input_mp%pmass)

        endif

!---------------------------------------------------------------------
!    output diagnostics for cloud drop number tendency and cloud drop 
!    number path tendency due to convection.
!---------------------------------------------------------------------
        if (do_liq_num) then
          if (id_qndt_conv > 0 .or. id_qn_conv_col > 0) then
            used = send_data (id_qndt_conv, Tend_mp%qndt_conv,    &
                                                       Time, is, js, 1)
            if (id_qn_conv_col > 0)     &
                call column_diag (id_qn_conv_col, is, js, Time,   &
                                  Tend_mp%qndt_conv, 1.0, Input_mp%pmass)
          endif
        endif

!---------------------------------------------------------------------
!    output diagnostics for cloud ice tendency and cloud ice water path 
!    tendency due to convection.
!---------------------------------------------------------------------
        if (id_qidt_conv > 0 .or. id_qi_conv_col > 0) then
          used = send_data (id_qidt_conv, Tend_mp%qidt_conv, Time,   &
                                                              is, js, 1)
          if (id_qi_conv_col > 0)    &
                call column_diag (id_qi_conv_col, is, js, Time,    &
                                  Tend_mp%qidt_conv, 1.0, Input_mp%pmass)
        endif        


!---------------------------------------------------------------------
!    output diagnostics for cloud ice number tendency and cloud ice number
!    path tendency due to convection.
!---------------------------------------------------------------------
        if (do_ice_num) then
          if (id_qnidt_conv > 0 .or. id_qni_conv_col > 0) then
            used = send_data (id_qnidt_conv, Tend_mp%qnidt_conv,    &
                                                         Time, is, js, 1)
            if (id_qni_conv_col > 0)   &
                 call column_diag (id_qni_conv_col, is, js, Time,   &
                                Tend_mp%qnidt_conv, 1.0, Input_mp%pmass)
          endif
        endif

!---------------------------------------------------------------------
!    output diagnostics for cloud area tendency and column integrated 
!    cloud mass tendency due to convection.
!---------------------------------------------------------------------
        if (id_qadt_conv > 0 .or.  id_qa_conv_col > 0 ) then
          used = send_data (id_qadt_conv, Tend_mp%qadt_conv,    &
                                                        Time, is, js, 1)
          if (id_qa_conv_col > 0)     &
               call column_diag (id_qa_conv_col, is, js, Time,    &
                                Tend_mp%qadt_conv, 1.0, Input_mp%pmass)
        endif
      endif !(doing_prog_clouds)
         
!---------------------------------------------------------------------
!    compute the column integrated enthalpy and total water tendencies 
!    due to convection parameterizations, if those diagnostics are desired.
!---------------------------------------------------------------------
      if (id_enth_conv_col > 0 .or. id_wat_conv_col > 0) then
        temp_3d1 = Output_mp%rdt(:,:,:,nql) - Output_mp%rdt_init(:,:,:,nql)
        temp_3d2 = Output_mp%rdt(:,:,:,nqi) - Output_mp%rdt_init(:,:,:,nqi)

        if (id_enth_conv_col > 0) then
          temp_2d = -HLV*Output_mp%precip -HLF*Output_mp%fprec
          call column_diag    &
             (id_enth_conv_col, is, js, Time, Tend_mp%ttnd_conv, CP_AIR, &
                  temp_3d1, -HLV, temp_3d2, -HLS, Input_mp%pmass, temp_2d)
        endif

        if (id_wat_conv_col > 0) then
          temp_2d = Output_mp%precip
          call column_diag   &
             (id_wat_conv_col, is, js, Time, Tend_mp%qtnd_conv, 1.0,   &
                   temp_3d1, 1.0, temp_3d2, 1.0, Input_mp%pmass, temp_2d)
        endif
      endif


!---------------------------------------------------------------------
!    compute the tracer tendencies due to convection for any tracers that
!    are to be transported by any convective parameterization.
!---------------------------------------------------------------------
      do n=1,size(Output_mp%rdt,4)
        if ( tracers_in_donner(n) .or.   &
             tracers_in_ras(n) .or.  &
             tracers_in_mca(n) .or.   &
             tracers_in_uw(n))    then
 
!---------------------------------------------------------------------
!    output diagnostics for tracer tendency and column integrated 
!    tracer tendency due to convection.
!---------------------------------------------------------------------
          if (id_tracerdt_conv(n) > 0 .or.    &
                                 id_tracerdt_conv_col(n) > 0) then
            temp_3d1 = Output_mp%rdt(:,:,:,n) - Output_mp%rdt_init(:,:,:,n)
            used = send_data (id_tracerdt_conv(n), temp_3d1,    &
                                                       Time, is, js, 1 )

            if (id_tracerdt_conv_col(n) > 0) &
              call column_diag    &
                  (id_tracerdt_conv_col(n), is, js, Time, temp_3d1,   &
                                                      1.0, Input_mp%pmass)
          endif        
        endif
      end do

!------------------------------------------------------------------


end subroutine convective_diagnostics



!######################################################################

subroutine define_convective_area (C2ls_mp, Moist_clouds_block, Input_mp)

!----------------------------------------------------------------------
!    subroutine define_convective_area computes the grid box area taken up
!    by convective clouds and thus unavailable to the large-scale cloud
!    scheme, and the ratio of gridbox relative humidity to that in the
!    convective cloud environment.
!----------------------------------------------------------------------

!---------------------------------------------------------------------
type(mp_conv2ls_type),              intent(inout) :: C2ls_mp
type(clouds_from_moist_block_type), intent(in)    :: Moist_clouds_block
type(mp_input_type),                intent(in)    :: Input_mp

!-----------------------------------------------------------------------
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Moist_clouds_block 
!               derived type used to transfer cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!
!----------------------------------------------------------------------

      real, dimension(size(Input_mp%t,1),size(Input_mp%t,2),   &
                                         size(Input_mp%t,3)) ::  &
                                             conv_area_input,  &
                                             rh_wtd_conv_area

!---------------------------------------------------------------------
!      conv_area_input  area taken up by convective clouds, summed over 
!                       the active convective schemes which predict clouds.
!                       this is the area unavailable for large-scale
!                       clouds.
!      rh_wtd_conv_area sum of convective area times relative humidity,
!                       summed over active convective cloud schemes 
!                       (relative-humidity-weighted convective area). 
!                       uw, donner cell and donner meso clouds above meso
!                       updraft level each contribute  CF*1.0 (their 
!                       cloud areas are assumed saturated), while the
!                       donner meso area below downdraft level but above
!                       cloud base contributes CF * an assumed height-
!                       dependent relative humidity (details in donner_deep
!                       parameterization.
!---------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define the total convective area and relative-humidity-weighted 
!    convective area for the current convective implementation.
!    if no convective scheme which produces convective clouds is active,
!    set these fields to 0.0.
!-----------------------------------------------------------------------
      if (do_uw_conv .and. do_donner_deep ) then
        conv_area_input = C2ls_mp%donner_humidity_area +  &
                    Moist_clouds_block%cloud_data(i_shallow)%cloud_area
        rh_wtd_conv_area =   &
                    Moist_clouds_block%cloud_data(i_cell)%cloud_area + &
                    C2ls_mp%donner_humidity_factor +  &
                    Moist_clouds_block%cloud_data(i_shallow)%cloud_area
      else if (do_donner_deep) then
        conv_area_input = C2ls_mp%donner_humidity_area 
        rh_wtd_conv_area =   &
                     Moist_clouds_block%cloud_data(i_cell)%cloud_area + &
                                           C2ls_mp%donner_humidity_factor 
      else if (do_uw_conv) then
        conv_area_input =   &
                    Moist_clouds_block%cloud_data(i_shallow)%cloud_area
        rh_wtd_conv_area = &
                    Moist_clouds_block%cloud_data(i_shallow)%cloud_area
      else
        conv_area_input = 0.
        rh_wtd_conv_area = 0.
      endif

!-----------------------------------------------------------------------
!    call compute_convective_area to compute the grid box area taken up 
!    by convective clouds, and the ratio of gridbox relative humidity to
!    that in the cloud environment.  If CLUBB is active, then a second call
!    is made using slightly different inputs, and with outputs that are 
!    used only with CLUBB. 
!-----------------------------------------------------------------------
      if (.not. do_lsc) then
        call compute_convective_area     &
            (Input_mp%tin, Input_mp%pfull, Input_mp%qin, conv_area_input, &
             rh_wtd_conv_area, 1.0, C2ls_mp%convective_humidity_ratio, &
                                         C2ls_mp%convective_humidity_area)
      endif
      if (do_clubb == 2) then
        call compute_convective_area     &
                   (Input_mp%t, Input_mp%pfull, Input_mp%q,   &
                       conv_area_input, rh_wtd_conv_area, conv_frac_max, &
                         C2ls_mp%convective_humidity_ratio_clubb,   &
                                                C2ls_mp%conv_frac_clubb)

      endif

!---------------------------------------------------------------------


end subroutine define_convective_area   



!#######################################################################

subroutine compute_convective_area     &
                 (t, pfull, q, conv_area_input, rh_wtd_conv_area,   &
                           max_cnv_frac, humidity_ratio, convective_area)

!-------------------------------------------------------------------------
!    subroutine compute_convective_area defines the grid box area affected
!    by the convective clouds (convective_area) and the ratio of the 
!    grid-box relative humidity to the humidity in the environment of the 
!    convective clouds (humidity_ratio). 
!-------------------------------------------------------------------------

real, dimension(:,:,:),  intent(in)   :: t, pfull, q, &
                                         conv_area_input, rh_wtd_conv_area
real,                    intent(in)   :: max_cnv_frac
real, dimension(:,:,:),  intent(out)  :: humidity_ratio, convective_area

!------------------------------------------------------------------------

!----------------------------------------------------------------------
!         t        temperature            [ K ]
!         pfull    pressure on full levels [ Pa ]
!         q        specific humidity [ kg h2o / kg moist air ]
!         conv_area_input
!                  convective cloud area as determined by active convective
!                  schemes
!         rh_wtd_conv_area
!                  sum of products of convective area * rh over all active
!                  convective cloud schemes
!         max_cnv_frac
!                 largest area in a gridbox which may be taken up by 
!                 convective clouds
!         humidity_ratio
!                 ratio of the grid-box relative humidity to the humidity 
!                 in the environment of the convective clouds  
!         convective_area 
!                 grid box area affected by the convective clouds 
!         
!----------------------------------------------------------------------

!----------------------------------------------------------------------
      real, dimension(size(t,1), size(t,2),   &
                             size(t,3)) :: qs, qrf, env_fraction, env_qv
      integer :: i, j ,k
      integer :: ix, jx, kx

!-----------------------------------------------------------------------
!      qs              saturation specific humidity
!      qrf             model specific humidity, forced to be realizable
!      env_fraction    portion of gridbox free of convective cloud 
!                      influence
!      env_qv          temporary variable used in calculation of
!                      humidity_ratio
!      i, j, k         do loop indices
!      ix, jx, kx      dimensions of physics window
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(t,1)
      jx = size(t,2)
      kx = size(t,3)

!-----------------------------------------------------------------------
!    define the grid box area whose humidity is affected by the 
!    convective clouds (convective_area) initially as that obtained from 
!    the active cloud schemes (conv_area_input) and passed into this 
!    subroutine. here it may be limited by max_cnv_frac, which may be set
!    either arbitrarily or by an nml variable. the convective environment 
!    fraction (env_fraction) is  defined as the remainder of the box.
!-----------------------------------------------------------------------
      do k=1, kx
        do j=1,jx   
          do i=1,ix  
            convective_area(i,j,k) = min (conv_area_input(i,j,k), &
                                                             max_cnv_frac)
            env_fraction(i,j,k) = 1.0 - convective_area(i,j,k)
          end do
        end do
      end do

!-----------------------------------------------------------------------
!    calculate the ratio of the gridbox relative humidity to that
!    in the cloud environment (humidity_ratio). to do so, define a 
!    realizable grid box specific humidity (qrf) and the saturation 
!    specific humidity (qs).
!------------------------------------------------------------------
      qrf = MAX(q, 0.0)
      call compute_qs (t, pfull, qs)

!----------------------------------------------------------------------
!    given the gridbox specific humidity (qrf) and the convective area
!    specific humidity (based on qs), the environmental specific humidity
!    must be given by
!
!      q(ENVIRONMENT) =  (q(GRIDBOX) -q(ConvectiveArea)*ConvectiveArea)/ &
!                                                     (1 - ConvectiveArea).
!
!    the convective cloud area is assumed saturated for the uw clouds, in 
!    the donner cell clouds and in the region of donner meso updraft, but 
!    is assumed subsaturated in the donner meso downdraft layer above cloud
!    base, with the degree of saturation given by the 
!    donner_humidity_factor (mesoscale area times assumed RH).
!
!    variable env_qv is defined as the numerator in the above expression.
!    where the ConvectiveArea has been passed in as rh_wtd_conv_area, 
!    taking account of the different treatment of qs in the cloud area by 
!    meso, cell and uw clouds.
!-------------------------------------------------------------------
      env_qv = qrf - qs*rh_wtd_conv_area
      do k=1,kx
        do j=1,jx   
          do i=1,ix  

!---------------------------------------------------------------------
!    one can define the ratio of the grid-box relative humidity to the 
!    humidity in the environment of the convective clouds only if the 
!    grid box contains vapor (qrf > 0.0) and there is some vapor
!    outside of the convective clouds (env_qv > 0.).
!----------------------------------------------------------------------
            if (qrf(i,j,k) /= 0.0 .and. env_qv(i,j,k) > 0.0) then
 
!--------------------------------------------------------------------
!    there must also be some grid box area that does not contain convective
!    clouds (env_fraction > 0.).
!--------------------------------------------------------------------  
              if (env_fraction(i,j,k) > 0.0) then
                humidity_ratio(i,j,k) =    &
                   MAX (qrf(i,j,k)*env_fraction(i,j,k)/env_qv(i,j,k), 1.0)
 
!---------------------------------------------------------------------
!    if the grid box is filled with convective clouds, set humidity ratio 
!    to a flag value. this will not happen if max_cnv_frac is < 1.0.
!----------------------------------------------------------------------
              else
                humidity_ratio(i,j,k) = -10.0
              endif

!--------------------------------------------------------------------
!    if there either is no vapor in the gridbox or all the vapor has been 
!    taken up by the convective clouds, set the humidity_ratio to 1.0.
!---------------------------------------------------------------------
            else
              humidity_ratio(i,j,k) = 1.0
            endif
          end do
        end do
      end do

!------------------------------------------------------------------------


end subroutine compute_convective_area



!######################################################################

subroutine define_inputs_for_cosp (Removal_mp)

!---------------------------------------------------------------------
!    subroutine define_inputs_for_cosp  converts the precip fluxes from
!    =mid-layer values to interface values.
!---------------------------------------------------------------------

type(mp_removal_type),  intent(inout) :: Removal_mp

!---------------------------------------------------------------------
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!---------------------------------------------------------------------

      integer :: k

!--------------------------------------------------------------------
!    k     do loop index
!--------------------------------------------------------------------

!---------------------------------------------------------------------
!    define precip fluxes from donner schemes at each layer interface. 
!    (index 1 is model lid)
!---------------------------------------------------------------------
      do k=2, size(Removal_mp%liq_mesoh,3)
        Removal_mp%liq_mesoh(:,:,k) = Removal_mp%liq_mesoh (:,:,k-1) + &
                                      Removal_mp%liq_meso (:,:,k-1)
        Removal_mp%frz_mesoh(:,:,k) = Removal_mp%frz_mesoh (:,:,k-1) + &
                                      Removal_mp%frz_meso (:,:,k-1)
        Removal_mp%liq_cellh(:,:,k) = Removal_mp%liq_cellh (:,:,k-1) + &
                                      Removal_mp%liq_cell (:,:,k-1)
        Removal_mp%frz_cellh(:,:,k) = Removal_mp%frz_cellh (:,:,k-1) + &
                                      Removal_mp%frz_cell (:,:,k-1)
        Removal_mp%ice_precflxh(:,:,k) =                  &
                                      Removal_mp%ice_precflxh(:,:,k-1) +  &
                                      Removal_mp%ice_precflx(:,:,k-1)
        Removal_mp%liq_precflxh(:,:,k) =        &
                                      Removal_mp%liq_precflxh(:,:,k-1) +  &
                                      Removal_mp%liq_precflx(:,:,k-1)
        if (include_donmca_in_cosp) then
          Removal_mp%mca_liqh(:,:,k) = Removal_mp%mca_liqh (:,:,k-1) + &
                                       Removal_mp%mca_liq(:,:,k-1)
          Removal_mp%mca_frzh(:,:,k) = Removal_mp%mca_frzh (:,:,k-1) + &
                                       Removal_mp%mca_frz(:,:,k-1)
        endif
      end do

!--------------------------------------------------------------------
!    adjust precip fluxes to remove any negative values that were produced.
!    precip contribution is determined as the negative of the total 
!    moisture tendency, so at top of clouds a positive moisture tendency 
!    sometimes results in a negative precipitation contribution. 
!----------------------------------------------------------------------
      call prevent_neg_precip_fluxes (Removal_mp%liq_mesoh)
      call prevent_neg_precip_fluxes (Removal_mp%frz_mesoh)
      call prevent_neg_precip_fluxes (Removal_mp%liq_cellh)
      call prevent_neg_precip_fluxes (Removal_mp%frz_cellh)
      call prevent_neg_precip_fluxes (Removal_mp%ice_precflxh)
      call prevent_neg_precip_fluxes (Removal_mp%liq_precflxh)
      if (include_donmca_in_cosp) then
        call prevent_neg_precip_fluxes (Removal_mp%mca_liqh)
        call prevent_neg_precip_fluxes (Removal_mp%mca_frzh)
      endif

!-----------------------------------------------------------------------


end subroutine define_inputs_for_cosp 



!#######################################################################

subroutine prevent_neg_precip_fluxes (fluxh)

!----------------------------------------------------------------------
!    subroutine prevent_neg_precip_fluxes checks for negative precip
!    fluxes (implying precip is moving upwards in the atmosphere) at each 
!    level, and if encountered the flux is eliminated.
!----------------------------------------------------------------------

real, dimension(:,:,:), intent(inout) :: fluxh

!---------------------------------------------------------------------
!  fluxh  precip flux at model half-level
!---------------------------------------------------------------------

      real, dimension(size(fluxh,1), size(fluxh,2)) :: sumneg
      integer :: i,j,k

!---------------------------------------------------------------------
!  sumneg      the accumulated vertical sum of unbalanced negative 
!              precip fluxes in the column (beginning at the top)
!  i, j, k     do loop indices
!---------------------------------------------------------------------

!-----------------------------------------------------------------------
!    move down each column looking for negative precip fluxes at each
!    level. if found, the negative flux is eliminated at the level, and 
!    positive fluxes lower down will be reduced until the negative flux 
!    is balanced.
!-----------------------------------------------------------------------
      sumneg(:,:) = 0.
      do k=2, size(fluxh,3)
        do j=1,size(fluxh,2)
          do i=1,size(fluxh,1)
            if (fluxh(i,j,k) > 0.0) then
              if (fluxh(i,j,k) > ABS(sumneg(i,j))) then
                fluxh(i,j,k) = fluxh(i,j,k) + sumneg(i,j)
                sumneg(i,j) = 0.
              else
                sumneg(i,j) = sumneg(i,j) + fluxh(i,j,k)
                fluxh(i,j,k) = 0.
              endif
            else
              sumneg(i,j) = sumneg(i,j) + fluxh(i,j,k)
              fluxh(i,j,k) = 0.
            endif
          end do
        end do
      end do

!----------------------------------------------------------------------


end subroutine prevent_neg_precip_fluxes



!#######################################################################

subroutine convection_driver_dealloc (Conv_results)

!--------------------------------------------------------------------
!    subroutine convection_driver_dealloc deallocates the components of
!    the conv_results_type variable Conv_results.
!--------------------------------------------------------------------

type(conv_results_type), intent(inout)   :: Conv_results

!---------------------------------------------------------------------
!    Conv_results
!               conv_results_type variable containing local variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!---------------------------------------------------------------------

!------------------------------------------------------------------------
!    deallocate the components of the conv_results_type variable
!    Conv_results.
!------------------------------------------------------------------------
      deallocate (Conv_results%ras_mflux)   ! old variable mc
      deallocate (Conv_results%ras_det_mflux) ! old variable det0
      if (do_donner_deep) then
        deallocate (Conv_results%donner_mflux) ! m_cellup
        deallocate (Conv_results%donner_det_mflux) ! m_cdet_donner
      endif
      deallocate (Conv_results%uw_mflux)  ! cmf
      deallocate (Conv_results%mc_donner)  
      deallocate (Conv_results%mc_donner_up)  
      deallocate (Conv_results%mc_donner_half)  

      deallocate(Conv_results%available_cf_for_uw)
      deallocate(Conv_results%conv_calc_completed)

      deallocate (Conv_results%cldtop) 
      deallocate (Conv_results%cldbot) 
      deallocate (Conv_results%prod_no) 

!----------------------------------------------------------------------


end subroutine convection_driver_dealloc



!*******************************************************************
!
!                     PRIVATE, DONNER-RELATED SUBROUTINES
!
!*******************************************************************

!######################################################################

subroutine donner_driver ( is, ie, js, je, Input_mp, Moist_clouds_block, &
                           Conv_results, C2ls_mp, Removal_mp, Tend_mp,  &
                           Output_mp)

!------------------------------------------------------------------------
!    subroutine donner_driver prepares for the execution of 
!    donner_deep_mod, calls its module driver, processes its
!    output into the form needed by other parameterizations active in 
!    the atmospheric model while assuring that output is realizable and
!    conserves desired properties, calls moist convective adjustment if 
!    that is executed as part of the donner scheme, and then outputs 
!    diagnostics from the donner scheme.
!------------------------------------------------------------------------

integer,                             intent(in)    :: is, ie, js, je
type(mp_input_type),                 intent(inout) :: Input_mp
type(clouds_from_moist_block_type),  intent(inout) :: Moist_clouds_block
type(conv_results_type),             intent(inout) :: Conv_results
type(mp_conv2ls_type),               intent(inout) :: C2ls_mp
type(mp_removal_type),               intent(inout) :: Removal_mp
type(mp_tendency_type),              intent(inout) :: Tend_mp
type(mp_output_type),                intent(inout) :: Output_mp
!------------------------------------------------------------------------

!----------------------------------------------------------------------
!    is,ie      starting and ending i indices for window
!    js,je      starting and ending j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Moist_clouds_block 
!               derived type used to transfer cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!----------------------------------------------------------------------

      type(donner_input_type)  :: Input_don
      type(conv_output_type)   :: Output_don
      type(conv_tendency_type) :: Don_tend, Don_mca_tend
      integer                  :: ix, jx, kx

!--------------------------------------------------------------------
!         Input_don       donner_input_type variable containing input
!                         fields used by donner_deep_mod
!         Output_don      conv_output_type variable containing output
!                         fields from donner_deep_mod
!         Don_tend        conv_tendency_type variable containing tendency
!                         output form donner_deep_mod
!         Don_mca_tend    conv_tendency_type variable containing tendency
!                         output from the moist convective adjustment 
!                         component of the donner deep convection scheme
!         ix, jx, kx      sizes of the physics window
!--------------------------------------------------------------------

!---------------------------------------------------------------------
!    activate the donner clock.
!---------------------------------------------------------------------
      call mpp_clock_begin (donner_clock)

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 

!-----------------------------------------------------------------------
!    call donner_alloc to allocate and initialize components of Input_don,
!    Output_don, Don_tend and Don_mca_tend.
!-----------------------------------------------------------------------
      call donner_alloc (ix, jx, kx, Input_don, Output_don, Don_tend, &
                                                             Don_mca_tend) 

!---------------------------------------------------------------------
!    call donner_prep to collect some additional inputs needed by the 
!    donner parameterization.
!---------------------------------------------------------------------
      call donner_prep (Input_mp, Input_don, Output_don)

!---------------------------------------------------------------------
!    call donner_deep to compute the effects of deep convection on the 
!    temperature, vapor mixing ratio, tracers, cloud liquid, cloud ice
!    cloud area and precipitation fields.
!---------------------------------------------------------------------
      call donner_deep     &
        (is, ie, js, je, dt, Input_mp%tin, Input_don%rin,    &
         Input_mp%pfull, Input_mp%phalf, Input_mp%zfull, Input_mp%zhalf,  &
         Input_mp%omega, Input_mp%pblht, Input_don%ke_bl, Input_mp%qstar, &
         Input_mp%cush, Input_mp%coldT, Input_mp%land,     &
         Input_don%sfc_sh_flux, Input_don%sfc_vapor_flux,   &
         Input_don%tr_flux, Output_don%donner_tracer,   &
         Input_don%secs, Input_don%days, Input_mp%cbmf,            &
         Moist_clouds_block%cloud_data(i_cell)%cloud_area, &
         Moist_clouds_block%cloud_data(i_cell)%liquid_amt, &
         Moist_clouds_block%cloud_data(i_cell)%liquid_size, &
         Moist_clouds_block%cloud_data(i_cell)%ice_amt    , &
         Moist_clouds_block%cloud_data(i_cell)%ice_size   , &
         Moist_clouds_block%cloud_data(i_cell)%droplet_number, &
         Moist_clouds_block%cloud_data(i_meso)%cloud_area, &
         Moist_clouds_block%cloud_data(i_meso)%liquid_amt, &
         Moist_clouds_block%cloud_data(i_meso)%liquid_size, &
         Moist_clouds_block%cloud_data(i_meso)%ice_amt    , &
         Moist_clouds_block%cloud_data(i_meso)%ice_size   , &
         Moist_clouds_block%cloud_data(i_meso)%droplet_number, &
         Moist_clouds_block%cloud_data(i_meso)%nsum_out, &
         Input_don%maxTe_launch_level,   &
         Output_don%precip_returned, Output_don%delta_temp,   &
         Output_don%delta_vapor, Conv_results%donner_det_mflux,   &
         Conv_results%donner_mflux, Conv_results%mc_donner,   &
         Conv_results%mc_donner_up,    &
         Conv_results%mc_donner_half, C2ls_mp%donner_humidity_area,    &
         C2ls_mp%donner_humidity_factor, Input_don%qtr,  &
         Removal_mp%donner_wetdep, Output_don%lheat_precip,   &
         Output_don%vert_motion, Output_don%total_precip,    &
         Output_don%liquid_precip, Output_don%frozen_precip, &
         Removal_mp%frz_meso,  Removal_mp%liq_meso, &
         Removal_mp%frz_cell, Removal_mp%liq_cell, &
         Input_don%qlin, Input_don%qiin, Input_don%qain,    &
         Output_don%delta_ql, Output_don%delta_qi, Output_don%delta_qa)  

!------------------------------------------------------------------------
!    call process_donner_output to 1) add tracer tendencies from 
!    donner_deep_mod to the arrays accumulating the total tracer 
!    tendencies, and 2) define the change in vapor specific humidity
!    resulting from donner_deep_mod.
!------------------------------------------------------------------------
      call process_donner_output (Input_don, Input_mp, Output_don,   &
                                                            Output_mp)

!------------------------------------------------------------------------
!    if column conservation checks on the water and enthalpy changes 
!    produced within the donner deep convection scheme have been requested,
!    call check_donner_conservation to compute the needed vertical 
!    integrals.
!------------------------------------------------------------------------
      if (do_donner_conservation_checks) then
        call check_donner_conservation (is, js, ie, je, Input_mp,   &
                                                             Output_don) 
      endif

!---------------------------------------------------------------------
!    scale the donner_deep_mod tendencies to prevent the formation of 
!    negative condensate, cloud areas smaller than a specified minimum,
!    and water vapor specific humidity below a specified limit. 
!---------------------------------------------------------------------
      if (doing_prog_clouds .and. do_limit_donner) then
        call define_and_apply_scale ( Input_mp, Don_tend, Output_don,&
                                      .true., .false., Input_don%qtr)
      endif

!---------------------------------------------------------------------
!    call prevent_unrealizable_water to adjust raw forcings from 
!    donner_deep so as to prevent unrealizable mixing ratios for 
!    water substance and cloud area, and to adjust precipitation field to 
!    force moisture conservation in each model column.
!---------------------------------------------------------------------
      call prevent_unrealizable_water    &
                             (Input_mp, Output_don, Removal_mp, Don_tend)

!------------------------------------------------------------------------
!    call define output fields to 1) define quantities needed for use by
!    other modules, 2) to update the input fields which will be supplied to
!    to other active moist_processes parameterizations, and 3) to define 
!    donner tendencies in the desired units used in moist_processes_mod. 
!------------------------------------------------------------------------
      call define_output_fields     &
                (Input_mp, Input_don, Output_don, Conv_results,   &
                                                      C2ls_mp, Don_tend)

!-----------------------------------------------------------------------
!    call update_outputs to update tendency fields in Output_mp% and
!    Don_tend% that are needed later.
!-----------------------------------------------------------------------
      call update_outputs (Don_tend, Output_mp,  Tend_mp)

!----------------------------------------------------------------------
!    this section calculates the moist convective adjustment associated
!    with the donner convection scheme. It is activated / deactivated
!    by moist_processes_nml variable do_donner_mca.
!----------------------------------------------------------------------
      if (do_donner_mca) then
        call donner_mca_driver     &
               (is, js, Input_mp, Input_don, Output_don, Removal_mp, &
                                               Output_mp, Don_mca_tend)
!-----------------------------------------------------------------------
!    call update_outputs to update tendency fields in Output_mp% and
!    Don_mca_tend% that are needed later.
!-----------------------------------------------------------------------
        call update_outputs ( Don_mca_tend, Output_mp, Tend_mp)
      endif !(do_donner_mca) 
                      
!------------------------------------------------------------------------
!    call output_donner_diagnostics to output netcdf diagnostics of 
!    diagnostic fields from donner_deep_mod.
!------------------------------------------------------------------------
      call output_donner_diagnostics    &
              (is, js, Input_mp, Conv_results, Moist_clouds_block,  &
                   Input_don, Output_don, C2ls_mp, Don_tend, Don_mca_tend)
                      
!----------------------------------------------------------------------
!    call donner_dealloc to deallocate the components of the derived types
!    local to this subroutine.
!----------------------------------------------------------------------
      call donner_dealloc (Input_don, Output_don, Don_tend, Don_mca_tend) 

!-----------------------------------------------------------------------
!    turn off the donner clock.
!-----------------------------------------------------------------------
      call mpp_clock_end (donner_clock)

!---------------------------------------------------------------------


end subroutine donner_driver



!#########################################################################

subroutine donner_alloc (ix, jx, kx, Input_don, Output_don, Don_tend, &
                                                      Don_mca_tend) 

!-----------------------------------------------------------------------
!    subroutine donner_alloc allocates the components of derived type
!    arrays local to subroutine donner_driver.
!-----------------------------------------------------------------------

!----------------------------------------------------------------------
integer,                  intent(in)    :: ix, jx, kx
type(donner_input_type),  intent(inout) :: Input_don
type(conv_output_type),   intent(inout) :: Output_don
type(conv_tendency_type), intent(inout) :: Don_tend, Don_mca_tend

!--------------------------------------------------------------------
!         ix, jx, kx      sizes of the physics window
!         Input_don       donner_input_type variable containing input
!                         fields used by donner_deep_mod
!         Output_don      conv_output_type variable containing output
!                         fields from donner_deep_mod
!         Don_tend        conv_tendency_type variable containing tendency
!                         output form donner_deep_mod
!         Don_mca_tend    conv_tendency_type variable containing tendency
!                         output from the moist convective adjustment 
!                         component of the donner deep convection scheme
!--------------------------------------------------------------------

!-------------------------------------------------------------------
!    allocate  and initialize the Don_mca_tend components.
!-------------------------------------------------------------------
      if (do_donner_mca) then
        allocate (Don_mca_tend%rain  (ix, jx))
        allocate (Don_mca_tend%snow  (ix, jx))
        allocate (Don_mca_tend%ttnd  (ix, jx, kx))
        allocate (Don_mca_tend%qtnd  (ix, jx, kx))
        allocate (Don_mca_tend%qtr   (ix, jx, kx, num_donner_tracers))

        Don_mca_tend%rain = 0.
        Don_mca_tend%snow = 0.
        Don_mca_tend%ttnd = 0.
        Don_mca_tend%qtnd = 0.
        Don_mca_tend%qtr  = 0.
      endif

!-------------------------------------------------------------------
!    allocate  and initialize the Don_tend components.
!-------------------------------------------------------------------
      allocate (Don_tend%delta_q  (ix, jx, kx))
      allocate (Don_tend%rain     (ix, jx))
      allocate (Don_tend%snow     (ix, jx))
      allocate (Don_tend%ttnd     (ix, jx, kx))
      allocate (Don_tend%qtnd     (ix, jx, kx))
      allocate (Don_tend%qtr      (ix, jx, kx, num_donner_tracers))
      if (doing_prog_clouds) then
        allocate (Don_tend%qltnd    (ix, jx, kx))
        allocate (Don_tend%qitnd    (ix, jx, kx))
        allocate (Don_tend%qatnd    (ix, jx, kx))
        allocate (Don_tend%qntnd    (ix, jx, kx))
        allocate (Don_tend%qnitnd   (ix, jx, kx))
      endif
      Don_tend%delta_q = 0.
      Don_tend%rain    = 0.
      Don_tend%snow    = 0.
      Don_tend%ttnd    = 0.
      Don_tend%qtnd    = 0.
      Don_tend%qtr     = 0.
      if (doing_prog_clouds) then
        Don_tend%qltnd  = 0.
        Don_tend%qitnd  = 0.
        Don_tend%qatnd  = 0.
        Don_tend%qntnd  = 0.
        Don_tend%qnitnd = 0.
      endif

!-------------------------------------------------------------------
!    allocate  and initialize the Input_don components.
!
!     sfc_sh_flux      sensible heat flux across the surface
!                      [ watts / m**2 ]
!     sfc_vapor_flux   water vapor flux across the surface
!                      [ kg(h2o) / (m**2 sec) ]
!     tr_flux          tracer fux across the surface
!                      [ kg(tracer) / (m**2 sec) ]
!----------------------------------------------------------------------
      allocate (Input_don%rin(ix, jx, kx) )
      allocate (Input_don%sfc_sh_flux(ix, jx) )
      allocate (Input_don%sfc_vapor_flux(ix, jx) )
      allocate (Input_don%tr_flux(ix, jx, num_donner_tracers) )
      allocate (Input_don%ke_bl(ix, jx) )
      allocate (Input_don%maxTe_launch_level(ix, jx) )
      allocate (Input_don%qtr(ix, jx, kx, num_donner_tracers) )
      allocate (Input_don%qlin(ix, jx, kx) )
      allocate (Input_don%qiin(ix, jx, kx) )
      allocate (Input_don%qain(ix, jx, kx) )
      allocate (Input_don%nllin(ix, jx, kx) )
      allocate (Input_don%nilin(ix, jx, kx) )
 
      Input_don%rin = 0.
      Input_don%sfc_sh_flux = 0.
      Input_don%sfc_vapor_flux = 0.
      Input_don%tr_flux = 0.
      Input_don%ke_bl = 0.
      Input_don%maxTe_launch_level = 0.
      Input_don%qtr = 0.
      Input_don%qlin = 0.
      Input_don%qiin = 0.
      Input_don%qain = 0.
      Input_don%nllin = 0.

!-------------------------------------------------------------------
!    allocate  and initialize the Output_don components.
!-------------------------------------------------------------------
      allocate (Output_don%delta_temp(ix, jx, kx))
      allocate (Output_don%delta_vapor(ix, jx, kx))
      allocate (Output_don%delta_q   (ix, jx, kx))
      allocate (Output_don%delta_ql  (ix, jx, kx))
      allocate (Output_don%delta_qi  (ix, jx, kx))
      allocate (Output_don%delta_qa  (ix, jx, kx))
      allocate (Output_don%delta_qn  (ix, jx, kx))
      allocate (Output_don%delta_qni (ix, jx, kx))
      allocate (Output_don%ttnd_adjustment(ix, jx, kx))
      allocate (Output_don%liquid_precip  (ix, jx, kx))
      allocate (Output_don%frozen_precip  (ix, jx, kx))
      allocate (Output_don%precip_adjustment(ix, jx))
      allocate (Output_don%precip_returned  (ix, jx))
      allocate (Output_don%adjust_frac      (ix, jx))
      allocate (Output_don%lheat_precip     (ix, jx))
      allocate (Output_don%vert_motion      (ix, jx))
      allocate (Output_don%total_precip     (ix, jx))
      allocate (Output_don%scale            (ix, jx))
      allocate (Output_don%scale_REV        (ix, jx))
      allocate (Output_don%donner_tracer    (ix, jx,kx,num_donner_tracers))

      Output_don%delta_temp = 0.
      Output_don%delta_vapor= 0.
      Output_don%delta_q    = 0.
      Output_don%delta_ql   = 0.
      Output_don%delta_qi   = 0.
      Output_don%delta_qa   = 0.
      Output_don%delta_qn   = 0.
      Output_don%delta_qni  = 0.
      Output_don%liquid_precip= 0.
      Output_don%frozen_precip= 0.
      Output_don%ttnd_adjustment = 0.
      Output_don%vert_motion = 0.
      Output_don%lheat_precip = 0.
      Output_don%total_precip = 0.
      Output_don%scale        = 1.0
      Output_don%scale_REV = 1.0
      Output_don%precip_adjustment = 0.
      Output_don%precip_returned   = 0.
      Output_don%adjust_frac       = 0.
      Output_don%donner_tracer     = 0.

!----------------------------------------------------------------------


end subroutine donner_alloc 
 


!#######################################################################

subroutine donner_prep (Input_mp, Input_don, Output_don)

!-----------------------------------------------------------------------
!    subroutine donner_prep consolidates the input fields needed by 
!    donner_deep_mod.
!-----------------------------------------------------------------------

type(mp_input_type),      intent(in)    :: Input_mp
type(donner_input_type),  intent(inout) :: Input_don
type(conv_output_type),   intent(inout) :: Output_don

!--------------------------------------------------------------------
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Input_don  donner_input_type variable containing input fields used by
!               donner_deep_mod
!    Output_don conv_output_type variable containing output fields from 
!               donner_deep_mod
!--------------------------------------------------------------------

      integer :: n, nn

!------------------------------------------------------------------------
!     n       do loop index
!     nn      counter
!------------------------------------------------------------------------

!--------------------------------------------------------------------
!    if prognostic clouds are active in the model, define the cloud liquid,
!    and cloud ice specific humidities, cloud area, and droplet and ice
!    particle numbers associated with them. if not using prognostic clouds,
!    these fields remain set to their initialized value of 0.0. 
!--------------------------------------------------------------------
      if (doing_prog_clouds) then
        Input_don%qlin = Input_mp%tracer(:,:,:,nql)
        Input_don%qiin = Input_mp%tracer(:,:,:,nqi)
        Input_don%qain = Input_mp%tracer(:,:,:,nqa)
        if (do_liq_num ) Input_don%nllin =  Input_mp%tracer(:,:,:,nqn)
        if (do_ice_num ) Input_don%nilin =  Input_mp%tracer(:,:,:,nqni)
      endif

!--------------------------------------------------------------------
!    convert vapor specific humidity to vapor mixing ratio, which is
!    needed in donner_deep_mod.
!--------------------------------------------------------------------
      Input_don%rin = Input_mp%qin/(1.0 - Input_mp%qin)

!---------------------------------------------------------------------
!    if any tracers are to be transported by donner convection, 
!    check each active tracer to find those to be transported and fill 
!    the donner_tracer array with these fields. If none are to be 
!    transported, the array remains at its initialized value of 0.0.
!---------------------------------------------------------------------
      if (num_donner_tracers > 0) then
        nn = 1
        do n=1,num_prog_tracers
          if (tracers_in_donner(n)) then
            Output_don%donner_tracer(:,:,:,nn) = Input_mp%tracer(:,:,:,n)
            nn = nn + 1
          endif
        end do
      endif

!---------------------------------------------------------------------
!    If one desires donner_deep_mod to see model-supplied surface fluxes of
!    sensible heat (Input_don%sfc_sh_flux), water vapor 
!    (Input_don%sfc_vapor_flux) or tracers  (Input_don%tr_flux), they
!    should be input here. They will need to be passed down in Surf_diff
!    from flux_exchange through moist_processes to convection_driver, and 
!    then to donner_deep through this interface.
!    FOR NOW, these values retain their initialized values of 0.0, as these
!    fields are not passed to donner_deep_mod.
!---------------------------------------------------------------------
!     Input_don%sfc_sh_flux    = 0.0
!     Input_don%sfc_vapor_flux = 0.0
!     if (num_donner_tracers > 0) then
!       nn = 1
!       do n=1, num_prog_tracers
!         if (tracers_in_donner(n)) then
!           Input_don%tr_flux(:,:,nn) = 0.0                          
!           nn = nn + 1
!         endif
!       end do
!     else
!       Input_don%tr_flux = 0.
!     endif

!-----------------------------------------------------------------------
!    define boundary layer kinetic energy to pass to donner deep routine.
!-----------------------------------------------------------------------
      Input_don%ke_bl = Input_mp%pblht
      Input_don%ke_bl = min(max(Input_don%ke_bl, 0.0),5000.)
      Input_don%ke_bl = Input_mp%ustar**3. +   &
                          0.6*Input_mp%ustar*Input_mp%bstar*Input_don%ke_bl
      where (Input_don%ke_bl .gt. 0.)
        Input_don%ke_bl = Input_don%ke_bl**(2./3.)
      end where
      Input_don%ke_bl = MAX (1.e-6, Input_don%ke_bl)

!----------------------------------------------------------------------
!    define model time in days and secs from base time.
!----------------------------------------------------------------------
      call get_time (Time, Input_don%secs, Input_don%days)

!---------------------------------------------------------------------


end subroutine donner_prep 



!#######################################################################

subroutine process_donner_output    &
                         (Input_don, Input_mp, Output_don, Output_mp)

!------------------------------------------------------------------------
type(donner_input_type),  intent(inout) :: Input_don
type(mp_input_type),      intent(inout) :: Input_mp
type(conv_output_type),   intent(inout) :: Output_don
type(mp_output_type),     intent(inout) :: Output_mp

!-------------------------------------------------------------------------
!    Input_don  donner_input_type variable containing input fields used by
!               donner_deep_mod
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_don conv_output_type variable containing output fields from 
!               donner_deep_mod
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!-------------------------------------------------------------------------

      real    :: qnew
      integer :: ix, jx, kx
      integer :: i, j, k, n, nn

!------------------------------------------------------------------------
!     qnew          updated specific humidity after donner is executed
!     ix, jx, kx    physics window sizes
!     i, j, k, n    do loop indice
!     nn            counter
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Output_mp%rdt, 1)
      jx = size(Output_mp%rdt, 2)
      kx = size(Output_mp%rdt, 3)

!---------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    just obtained from donner convection.
!---------------------------------------------------------------------
      if (num_donner_tracers > 0) then
        nn = 1
        do n=1, num_prog_tracers
          if (tracers_in_donner(n)) then
            Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                                   Input_don%qtr(:,:,:,nn)
            nn = nn + 1
          endif
        end do
      endif

!--------------------------------------------------------------------
!    obtain updated vapor specific humidity (qnew) resulting from deep 
!    convection  so that the vapor specific humidity change due to deep 
!    convection (delta_q) can be defined.
!--------------------------------------------------------------------
      do k=1,kx
        do j=1,jx
          do i=1,ix
            if (Output_don%delta_vapor(i,j,k) /= 0.0) then
              qnew =    &
                  (Input_don%rin(i,j,k) + Output_don%delta_vapor(i,j,k))/ &
                        (1.0 + (Input_don%rin(i,j,k) +     &
                                            Output_don%delta_vapor(i,j,k)))
              Output_don%delta_q(i,j,k) = qnew - Input_mp%qin(i,j,k)
            else
              Output_don%delta_q(i,j,k) = 0.
            endif
          enddo
        enddo
      end do

!---------------------------------------------------------------------


end subroutine process_donner_output 



!#######################################################################

subroutine check_donner_conservation (is, js, ie, je, Input_mp,   &
                                                             Output_don) 

!-----------------------------------------------------------------------
!    subroutine check_donner_conservation checks the water substance
!    and enthalpy changes in model columns as a result of donner deep
!    convection, and provides netcdf output of the appropriate terms and
!    net imbalances. Note that this is the raw output from the donner 
!    scheme so that moisture imbalances are to be expected at this 
!    juncture; they will be balanced if moisture conservation is enforced 
!    in subroutine prevent_unrealizable_water.
!    a second call to this subroutine after adjustments are completed
!    is recommended if it is desired to see final balances. {ADD NEW CODE
!    TO ENABLE THIS OPTION.}
!-----------------------------------------------------------------------

!---------------------------------------------------------------------
integer,                  intent(in)    :: is, ie, js, je
type(mp_input_type),      intent(inout) :: Input_mp
type(conv_output_type),   intent(inout) :: Output_don

!-------------------------------------------------------------------------
!    is,ie      starting and ending i indices for window
!    js,je      starting and ending j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_don conv_output_type variable containing output fields from 
!               donner_deep_mod
!-------------------------------------------------------------------------
!------------------------------------------------------------------------
      real, dimension( size(Input_mp%t,1), size(Input_mp%t,2)) ::    &
                          vaporint, lcondensint, condensint, diffint,   &
                          enthint, enthdiffint, precipint
      integer :: k, i, j
      integer :: kx
      logical :: used

!-------------------------------------------------------------------------
!    vertical integrals in each model column.
!      vaporint:    pressure-weighted sum of vapor changes in column
!      lcondensint: presuure-weighted sum of latent heat release in column
!      condensint:  pressure-weighted sum of condensation in the column
!      diffint:     imbalance between water substance change in column;  
!                   the sum of vapor change (vaporint) should balance the
!                   column precipitation (precipint) and the condensate
!                   transferred to the large-scale (condensint) 
!      enthint :    pressure-weighted sum of enthalpy changes in column
!      enthdiffint: imbalance in enthalpy change in column:
!                   the enthalpy change in the column should be balanced by
!                   the enthalpy associated with the latent heat removed by
!                   1) condensate that was transferred to the large-scale 
!                   clouds (lcondensint), and 2) lost by precipitation 
!                   (lheat_precip). An additional roundoff term due to
!                   column vertical motion is also included (vert_motion).
!      precipint:   precipitation rate from column
!
!      i, j, k:     do loop indices
!      kx           vertical size of physics window
!      used         logical used to indicate data has been received by
!                   diag_manager_mod
!-------------------------------------------------------------------------

!------------------------------------------------------------------------
!    define vertical array size. initialize vertical integrals.
!------------------------------------------------------------------------
      kx = size(output_don%delta_temp,3)

!--------------------------------------------------------
!    initialize column integrals.
!--------------------------------------------------------
      vaporint = 0.
      lcondensint = 0.
      condensint = 0.
      diffint = 0.
      enthint = 0.
      enthdiffint = 0.
    
!------------------------------------------------------------------------
!    compute vertical integrals in each model column.
!------------------------------------------------------------------------
      do k=1,kx
        vaporint = vaporint + Input_mp%pmass(:,:,k)*  &
                                                  Output_don%delta_q(:,:,k)
        enthint = enthint + CP_AIR*Input_mp%pmass(:,:,k)*   &
                                               Output_don%delta_temp(:,:,k)
        condensint = condensint + Input_mp%pmass(:,:,k) *  &
                  (Output_don%delta_ql(:,:,k) + Output_don%delta_qi(:,:,k))
        lcondensint = lcondensint + Input_mp%pmass(:,:,k) *  &
                                   (HLV*Output_don%delta_ql(:,:,k) +   &
                                            HLS*Output_don%delta_qi(:,:,k))
      end do

      precipint = Output_don%total_precip/seconds_per_day
      diffint = (vaporint + condensint)*dtinv  + precipint
      enthdiffint = (enthint - lcondensint)*dtinv -    &
                                Output_don%lheat_precip/seconds_per_day - &
                                     Output_don%vert_motion/seconds_per_day

!------------------------------------------------------------------------
!    update the variable collecting the maximum imbalance over the entire
!    model run, if the present imbalance value is larger than the 
!    previously recorded.
!------------------------------------------------------------------------
      do j=1,size(enthdiffint,2)
        do i=1,size(enthdiffint,1)
          max_enthalpy_imbal_don(i+is-1,j+js-1) =    &
                         max( abs(enthdiffint(i,j)), &
                                    max_enthalpy_imbal_don(i+is-1,j+js-1) )
          max_water_imbal_don(i+is-1,j+js-1) =     &
                         max( abs(diffint(i,j)), &
                                       max_water_imbal_don(i+is-1,j+js-1) )
        end do
      end do

!------------------------------------------------------------------------
!    output diagnostics related to water and enthalpy conservation.
!------------------------------------------------------------------------
      used = send_data(id_max_enthalpy_imbal_don,    &
                       max_enthalpy_imbal_don(is:ie,js:je), Time, is, js)
      used = send_data(id_max_water_imbal_don,     &
                          max_water_imbal_don(is:ie,js:je), Time, is, js)
      used = send_data(id_vaporint, vaporint*dtinv, Time, is, js)
      used = send_data(id_condensint, condensint*dtinv, Time, is, js)
      used = send_data(id_vertmotion,   &
                              Output_don%vert_motion/seconds_per_day,  &
                                                             Time, is, js)
      used = send_data(id_precipint, precipint, Time, is, js)
      used = send_data(id_diffint, diffint, Time, is, js)
      used = send_data(id_enthint, enthint*dtinv, Time, is, js)
      used = send_data(id_lcondensint, lcondensint*dtinv, Time, is, js)
      used = send_data(id_lprcp, Output_don%lheat_precip/seconds_per_day, &
                                                             Time, is, js)
      used = send_data(id_enthdiffint, enthdiffint, Time, is, js)

!-------------------------------------------------------------------------


end subroutine check_donner_conservation 



!#######################################################################

subroutine prevent_unrealizable_water     &
                             (Input_mp, Output_don, Removal_mp, Don_tend)

!--------------------------------------------------------------------------
!    subroutine prevent_unrealizable_water adjusts the tendencies coming 
!    out of the donner deep parameterization to prevent the formation of 
!    negative water vapor, liquid or ice.
!--------------------------------------------------------------------------

!-------------------------------------------------------------------------
type(mp_input_type),      intent(inout) :: Input_mp
type(mp_removal_type),    intent(inout) :: Removal_mp
type(conv_output_type),   intent(inout) :: Output_don
type(conv_tendency_type), intent(inout) :: Don_tend
!-----------------------------------------------------------------------

!----------------------------------------------------------------------
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Output_don conv_output_type variable containing output fields from 
!               donner_deep_mod
!    Don_tend   conv_tendency_type variable containing tendency output from
!               donner_deep_mod
!-----------------------------------------------------------------------

      real, dimension(size(Output_don%delta_q,1),    &
                               size(Output_don%delta_q,2)) :: temp_2d
      integer :: ix, jx, kx
      integer :: i, j, k, n
      integer :: nn

!------------------------------------------------------------------------
!    temp_2d        temporary array
!    ix, jx, kx     physics window dimensions
!    i, j, k, n     do loop indices
!    nn             counter
!----------------------------------------------------------------------

!------------------------------------------------------------------------
!    define array sizes.
!------------------------------------------------------------------------
      ix = size(Input_mp%qin,1)
      jx = size(Input_mp%qin,2)
      kx = size(Input_mp%qin,3)

!----------------------------------------------------------------------
!    if limiting tendencies is active, scale the precipitation fields and 
!    associated enthalpy terms. precip returned from Donner scheme is 
!    recalculated below, after the adjustments (precip_returned).
!----------------------------------------------------------------------
      if (doing_prog_clouds .and. do_limit_donner) then
        do j=1,jx
          do i=1,ix
            if (Output_don%scale(i,j) /= 1.0) then
              Output_don%total_precip(i,j) =   &
                             Output_don%scale(i,j)* &
                                               Output_don%total_precip(i,j)
              Output_don%lheat_precip(i,j) =   &
                             Output_don%scale(i,j)* &
                                              Output_don%lheat_precip(i,j)
              do k=1, kx
                Output_don%liquid_precip(i,j,k) =    &
                              Output_don%scale(i,j)*  &
                                           Output_don%liquid_precip(i,j,k)
                Output_don%frozen_precip(i,j,k) =    &
                              Output_don%scale(i,j)*  &
                                           Output_don%frozen_precip(i,j,k)
              end do
            endif
          end do
        end do

!---------------------------------------------------------------------
!    prevent liquid and frozen precip from having negative values.
!-------------------------------------------------------------------------
        where ( Output_don%liquid_precip(:,:,:) .lt. 0.)
          Output_don%liquid_precip(:,:,:) = 0.0
        end where

        where ( Output_don%frozen_precip(:,:,:) .lt. 0.)
          Output_don%frozen_precip(:,:,:) = 0.0
        end where

!-------------------------------------------------------------------------
!    dimensions of liquid_precip is [kg(H20)/(kg s)]*(SECONDS_PER_DAY)
!    dimensions of frozen_precip is [kg(H20)/(kg s)]*(SECONDS_PER_DAY)
!
!    Note that (dt/seconds_per_day) * sum of (liquid_precip(k) + 
!    frozen_precip( k) *pmass(k)) gives precip_returned.
!-------------------------------------------------------------------------
        Output_don%precip_returned(:,:) = 0.0
        do k=1, kx
          Output_don%precip_returned(:,:) =    &
                Output_don%precip_returned(:,:) +   &
                    (Output_don%liquid_precip(:,:,k) +     &
                           Output_don%frozen_precip(:,:,k))*  &
                                 Input_mp%pmass(:,:,k) *dt/SECONDS_PER_DAY
        end do

      endif  ! doing_clouds and do_limit_donner)

!-----------------------------------------------------------------------
!    if one is to force moisture conservation with donner, then determine
!    the imbalance between the net pressure-weighted moisture changes in
!    each column and the predicted precip in that column (they should be
!    equal). this difference is Output_don%precip_adjustment.
!-----------------------------------------------------------------------
      if (force_donner_moist_conserv) then
        temp_2d = 0.
        do k=1,kx
          temp_2d (:,:) = temp_2d (:,:) + (-Output_don%delta_q(:,:,k) -  &
                              Output_don%delta_ql(:,:,k) -   &
                                       Output_don%delta_qi(:,:,k))*  &
                                                      Input_mp%pmass(:,:,k)
        end do
        Output_don%precip_adjustment = (temp_2d -    &
                                             Output_don%precip_returned)

!---------------------------------------------------------------------
!    process the water imbalance, so that it is resolved. define a new 
!    scale (scale_REV) for those cases where donner convection must be 
!    turned off because it will produce negative values of precipitation.
!---------------------------------------------------------------------
        Output_don%scale_REV = Output_don%scale
        do j=1,jx
          do i=1,ix

!---------------------------------------------------------------------
!    If the net change of water content is less than qmin, the imbalance
!    is ignored.
!---------------------------------------------------------------------
            if (ABS(Output_don%precip_adjustment(i,j)) < 1.0e-10) then
              Output_don%precip_adjustment (i,j) = 0.0
            endif

!-----------------------------------------------------------------------
!    a net gain to the sum of vapor, liquid and ice in the column implies
!    negative precip, which is unrealizable. in such a case any precip 
!    that had been predicted in the column is zeroed out, and the effects
!    of donner convection on the column become non-existent. note that 
!    additional arrays associated with the precip field must be modified 
!    for consistency when a change is made, and any non-zero value for 
!    scale is set to 0.0.
!---------------------------------------------------------------------
            if ( Output_don%precip_adjustment(i,j) < 0.0 .and. &
                     (Output_don%precip_adjustment(i,j) +    &
                              Output_don%precip_returned(i,j)) < 0.0 ) then
!             write (warn_mesg,'(2i4,2e12.4)') i,j,  &
!                       precip_adjustment(i,j), precip_returned(i,j)
!             call error_mesg ('moist_processes_mod', 'moist_processes: &
!                 &Change in water content does not balance precip &
!                 &from donner_deep routine.'//trim(warn_mesg), WARNING)
              Output_don%scale_REV(i,j) = 0.0
              Output_don%delta_vapor(i,j,:) = 0.0
              Output_don%delta_q(i,j,:) = 0.0
              Output_don%delta_qi(i,j,:) = 0.0
              Output_don%delta_ql(i,j,:) = 0.0
              Output_don%delta_qa(i,j,:) = 0.0
              Output_don%total_precip(i,j) = 0.0
              Output_don%precip_returned(i,j) = 0.0
              Output_don%liquid_precip(i,j,:) = 0.0
              Output_don%frozen_precip(i,j,:) = 0.0
              Output_don%lheat_precip(i,j) = 0.0
            endif
          end do
        end do

!---------------------------------------------------------------------
!    define the fractional change to the  precipitation that must be made
!    in order to balance the net change in water in the column.
!---------------------------------------------------------------------
        do j=1,jx
          do i=1,ix
            if (Output_don%precip_returned(i,j) > 0.0) then
              Output_don%adjust_frac(i,j) =     &
                          Output_don%precip_adjustment(i,j)/  &
                                         Output_don%precip_returned(i,j)
            else
              Output_don%adjust_frac(i,j) = 0.
            endif
          end do
        end do

!---------------------------------------------------------------------
!    if the predicted precip exceeds the net loss to vapor, liquid and 
!    ice in the column, the precip is reduced  by the adjustment fraction
!    so that a balance is obtained (adjust_frac is negative). 
!    if the predicted precip is less than the net loss of vapor, liquid 
!    and ice from the column, the precip is increased by the adjustment
!    fraction to balance that net loss adjust_frac is positive). 
!    also adjust the temperature to balance the precip adjustment
!    and so conserve enthalpy in the column, and  define the new values
!    of liquid and frozen precipitation after adjustment.
!--------------------------------------------------------------------- 
        do k=1,kx
          Output_don%ttnd_adjustment(:,:,k) = &
                    ((HLV*Output_don%liquid_precip(:,:,k)*  &
                                         Output_don%adjust_frac(:,:) + &
                      HLS*Output_don%frozen_precip(:,:,k)*  &
                                        Output_don%adjust_frac(:,:))  &
                                               *dt/seconds_per_day)/CP_AIR
          Output_don%liquid_precip(:,:,k) =    &
                        Output_don%liquid_precip(:,:,k)*  &
                                         (1.0+Output_don%adjust_frac(:,:))
          Output_don%frozen_precip(:,:,k) =   &
                         Output_don%frozen_precip(:,:,k)*   &
                                          (1.0+Output_don%adjust_frac(:,:))
        end do

!------------------------------------------------------------------------
!    define the adjustments to be 0.0 if conservation is not being forced.
!------------------------------------------------------------------------
      else ! (force_donner_moist_conserv)
        Output_don%precip_adjustment = 0.0
        Output_don%adjust_frac       = 0.0
        Output_don%ttnd_adjustment = 0.
      endif  ! (force_donner_moist_conserv)

!-------------------------------------------------------------------------
!    define the column rainfall and snowfall from the donner scheme,
!    using the recently-adjusted values.
!-------------------------------------------------------------------------
      do k=1,kx
        Don_tend%rain = Don_tend%rain + Output_don%liquid_precip(:,:,k)*  &
                                    Input_mp%pmass(:,:,k)/seconds_per_day
        Don_tend%snow = Don_tend%snow + Output_don%frozen_precip(:,:,k)*  &
                                    Input_mp%pmass(:,:,k)/seconds_per_day
      end do

!----------------------------------------------------------------------
!   modify the 3d precip fluxes used by COSP to account for the 
!   conservation adjustment.
!----------------------------------------------------------------------
      if (do_cosp) then
        do k=1, kx
          do j=1,jx  
            do i=1,ix  
              Removal_mp%frz_meso(i,j,k) =   &
                   Removal_mp%frz_meso(i,j,k)*Input_mp%pmass(i,j,k)*  &
                             Output_don%scale_REV(i,j)* &
                                 (1.0 + Output_don%adjust_frac(i,j))/  &
                                                           SECONDS_PER_DAY
              Removal_mp%liq_meso(i,j,k) =    &
                   Removal_mp%liq_meso(i,j,k)*Input_mp%pmass(i,j,k)*  &
                              Output_don%scale_REV(i,j)* &
                                  (1.0 + Output_don%adjust_frac(i,j))/  &
                                                           SECONDS_PER_DAY
              Removal_mp%frz_cell(i,j,k) =    &
                   Removal_mp%frz_cell(i,j,k)*Input_mp%pmass(i,j,k)*   &
                               Output_don%scale_REV(i,j)* &
                                  (1.0 + Output_don%adjust_frac(i,j))/  &
                                                           SECONDS_PER_DAY
              Removal_mp%liq_cell(i,j,k) =    &
                   Removal_mp%liq_cell(i,j,k)*Input_mp%pmass(i,j,k)*   &
                                Output_don%scale_REV(i,j)* &
                                 (1.0 + Output_don%adjust_frac(i,j))/   &
                                                           SECONDS_PER_DAY
            end do
          end do
        end do
      endif 

!------------------------------------------------------------------------


end subroutine prevent_unrealizable_water



!#######################################################################


subroutine define_output_fields   &
                 (Input_mp, Input_don, Output_don, Conv_results,   &
                                                   C2ls_mp, Don_tend)
                      
!------------------------------------------------------------------------
!    subroutine define_output_fields 1) defines quantities needed for use
!    by other modules, 2) updates the input fields which will be supplied
!    to other active moist_processes parameterizations, and 3) defines 
!    donner tendencies in the desired units used in moist_processes_mod. 
!-------------------------------------------------------------------------

type(mp_input_type),        intent(inout) :: Input_mp
type(donner_input_type),    intent(inout) :: Input_don
type(conv_output_type),     intent(inout) :: Output_don
type(conv_results_type),    intent(inout) :: Conv_results
type(mp_conv2ls_type),      intent(in)    :: C2ls_mp
type(conv_tendency_type),   intent(inout) :: Don_tend

!-----------------------------------------------------------------------
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Input_don  donner_input_type variable containing input
!               fields used by donner_deep_mod
!    Output_don conv_output_type variable containing output
!               fields from donner_deep_mod
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Don_tend   conv_tendency_type variable containing tendency
!               output form donner_deep_mod
!---------------------------------------------------------------------

      real, dimension(size(Input_mp%t,1), size(Input_mp%t,2),      &
                                     size(Input_mp%t,3)) :: targ, qarg
      logical, dimension(size(Input_mp%t,1),size( Input_mp%t,2)) :: ltemp

      integer :: ix, jx, kx
      logical :: used
      integer :: i, j, k

!-----------------------------------------------------------------------
!   targ            variable to hold temperature field passed to
!                   subroutine detr_ice_num. that field will vary dependent
!                   on namelist options selected
!   qarg            variable to hold specific humidity field passed to
!                   subroutine detr_ice_num. that field will vary dependent
!                   on namelist options selected
!   ltemp           temporary logical variable
!   ix, jx, kx      physics window dimensions
!   used            logical used to indicate data has been received by
!                   diag_manager_mod
!   i, j, k         do loop indices
!-----------------------------------------------------------------------

!------------------------------------------------------------------------
!    define array dimensions.
!------------------------------------------------------------------------
      ix = size(Input_mp%t,1)
      jx = size(Input_mp%t,2)
      kx = size(Input_mp%t,3)

!-------------------------------------------------------------------------
!    if the option to allow only one convective scheme per column is
!    active, mark those columns which have undergone donner convection
!    so they will not be used in any other convection scheme.
!-------------------------------------------------------------------------
      if (only_one_conv_scheme_per_column) then
        Conv_results%conv_calc_completed =    &
                                  (Don_tend%rain + Don_tend%snow) > 0.0
      endif

!-----------------------------------------------------------------------
!    if a realizability constraint is to be placed on total cloud fraction,
!    define the area remaining available for clouds from other schemes 
!    after the donner cloud area has been accounted for.
!    Note also that if the entire area (>= 0.999) at any level is taken 
!    up by donner clouds, then uw clouds will not be allowed in the 
!    column ( set conv_calc_completed = T).
!-----------------------------------------------------------------------
      if (limit_conv_cloud_frac) then
        ltemp = ANY(C2ls_mp%donner_humidity_area(:,:,:) >= 0.999,   &
                                                                  dim = 3)
        where (ltemp(:,:)) Conv_results%conv_calc_completed(:,:) = .true.
        Conv_results%available_cf_for_uw = MAX(0.999 -    &
                                 C2ls_mp%donner_humidity_area(:,:,:), 0.0)
      endif

!---------------------------------------------------------------------
!    convert the deltas in temperature, vapor specific humidity and 
!    precipitation resulting from donner convection to time tendencies 
!    of these quantities. include the temperature adjustment made due
!    to adjustments to ensure positive water fields.
!---------------------------------------------------------------------
      Don_tend%ttnd = Output_don%delta_temp*dtinv 
      Don_tend%ttnd = Don_tend%ttnd + Output_don%ttnd_adjustment*dtinv

      Don_tend%qtnd  = Output_don%delta_q*dtinv
      Don_tend%qltnd = Output_don%delta_ql*dtinv
      Don_tend%qitnd = Output_don%delta_qi*dtinv
      Don_tend%qatnd = Output_don%delta_qa*dtinv

!---------------------------------------------------------------------
!    update the values of temperature and vapor specific humidity to
!    include the effects of donner_deep convection. if mca was included 
!    in the donner deep scheme, then this update has already been done.
!    define targ and qarg, the values to be passed to subroutine 
!    detrain_ice_num. The ability to reproduce old buggy results  where
!    detrain_ice_num received an un-updated temperature field is retained 
!    at this time.
!---------------------------------------------------------------------
      if (keep_icenum_detrain_bug .and. .not. do_donner_mca) then 
        targ = Input_mp%tin
        qarg = Input_mp%qin
        Input_mp%tin = Input_mp%tin + Output_don%delta_temp
        Input_mp%qin = Input_mp%qin + Output_don%delta_q(:,:,:)
      else
        Input_mp%tin = Input_mp%tin + Output_don%delta_temp
        Input_mp%qin = Input_mp%qin + Output_don%delta_q
        targ = Input_mp%tin
        qarg = Input_mp%qin
      endif

      if (doing_prog_clouds) then

!------------------------------------------------------------------------
!    calculate the amount of ice particles detrained from the donner
!    convective clouds. Modify the ice particle number and ice particle
!    number tendency from physics to account for this detrainment.  output
!    a diagnostic if desired.
!------------------------------------------------------------------------
        if (do_ice_num .and. detrain_ice_num) then
          call detr_ice_num (targ, Output_don%delta_qi,   &
                                                     Output_don%delta_qni) 
          Don_tend%qnitnd = Output_don%delta_qni*dtinv
        endif  

!-------------------------------------------------------------------------
!    detrain liquid droplets if desired. the original code had a bug which
!    may be preserved for test purposes with the remain_detrain_bug nml
!    variable. assume 10 micron mean volume radius for detrained droplets. 
!    Modify the particle number and particle number tendency from physics 
!    to account for this detrainment. output a diagnostic if desired.
!-------------------------------------------------------------------------
        if (do_liq_num .and. detrain_liq_num) then
          if (remain_detrain_bug ) then
            Output_don%delta_qn =  Output_don%delta_ql/1000.*3./  &
                                                        (4.*3.14*10.e-15)
          else
            Output_don%delta_qn =  Output_don%delta_ql/1000.*3./  &
                                                            (4.*3.14e-15)
          endif 
          Don_tend%qntnd = Output_don%delta_qn*dtinv
        endif

!-----------------------------------------------------------------------
!    update the largescale cloud fields and their total tendencies from
!    physics  with the tendencies resulting from the donner deep 
!    convection scheme.
!-----------------------------------------------------------------------
        Input_mp%tracer(:,:,:,nql) = Input_don%qlin + Output_don%delta_ql
        Input_mp%tracer(:,:,:,nqi) = Input_don%qiin + Output_don%delta_qi
        Input_mp%tracer(:,:,:,nqa) = Input_don%qain + Output_don%delta_qa
        if (do_ice_num .and. detrain_ice_num) then
          Input_mp%tracer(:,:,:,nqni) =  Input_don%nilin  +   &
                                                     Output_don%delta_qni 
        endif  
        if (do_liq_num .and. detrain_liq_num) then
          Input_mp%tracer(:,:,:,nqn) =  Input_don%nllin +   &
                                                      Output_don%delta_qn 
        endif
      endif  ! doing_prog_clouds

!-----------------------------------------------------------------------


end subroutine define_output_fields 



!#######################################################################

subroutine donner_mca_driver (is, js, Input_mp, Input_don, Output_don,  &
                                   Removal_mp, Output_mp, Don_mca_tend)

!-----------------------------------------------------------------------
!    subroutine donner_mca_driver makes the call to moist convective
!    adjustment that may be a part of the donner deep parameterization.
!-----------------------------------------------------------------------

!---------------------------------------------------------------------
integer,                  intent(in)    :: is, js               
type(mp_input_type),      intent(inout) :: Input_mp
type(donner_input_type),  intent(inout) :: Input_don
type(conv_output_type),   intent(inout) :: Output_don
type(mp_removal_type),    intent(inout) :: Removal_mp
type(mp_output_type),     intent(inout) :: Output_mp
type(conv_tendency_type), intent(inout) :: Don_mca_tend
!---------------------------------------------------------------------

!-----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Input_don  donner_input_type variable containing input
!               fields used by donner_deep_mod
!    Output_don conv_output_type variable containing output
!               fields from donner_deep_mod
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Don_mca_tend  
!               conv_tendency_type variable containing tendency
!               output from  the mca component of donner convection
!-----------------------------------------------------------------------
              
      integer :: ix, jx, kx
      integer :: i, j, k, n
      integer :: nn

!-----------------------------------------------------------------------
!    ix, jx, kx       physics window dimensions
!    i, j, k, n       do loop indices
!    nn               counter
!-----------------------------------------------------------------------

!------------------------------------------------------------------------
!    define array dimensions.
!------------------------------------------------------------------------
      ix = size(Input_mp%tin, 1)
      jx = size(Input_mp%tin, 2)
      kx = size(Input_mp%tin, 3)

!----------------------------------------------------------------------
!    if donner mca is active, turn on its clock.
!----------------------------------------------------------------------
      call mpp_clock_begin (donner_mca_clock)

!--------------------------------------------------------------------
!    call subroutine moist_conv to handle any shallow convection present 
!    in the grid. this call is made without the optional lsc variables so 
!    that no convective detrainment (and corresponding change in 
!    large-scale cloud amount and area) occurs, consistent with this call 
!    being intended to handle only shallow convection. The temp and vapor
!    fields are updated with any changes from deep convection before the 
!    routine is called.
!--------------------------------------------------------------------
      call moist_conv (Input_mp%tin, Input_mp%qin, Input_mp%pfull,  &
                  Input_mp%phalf, Input_mp%coldT, Don_mca_tend%ttnd, &
                  Don_mca_tend%qtnd, Don_mca_tend%rain, Don_mca_tend%snow,&
                  dtinv, Time, is, js, Output_don%donner_tracer,   &
                                                           Input_don%qtr )

!-----------------------------------------------------------------------
!    if the effects of the mca component of donner are to be seen by
!    COSP, define the associated precip fluxes.
!-----------------------------------------------------------------------
      if (do_cosp .and. include_donmca_in_cosp) then
        do j=1,jx 
          do i=1,ix 
            if (Input_mp%coldT(i,j)) then
              do k=1,kx
                Removal_mp%mca_frz(i,j,k) =    &
                        -1.0*Don_mca_tend%qtnd(i,j,k)*Input_mp%pmass(i,j,k)
                Removal_mp%mca_liq(i,j,k) = 0.
              end do
            else
              do k=1,kx
                Removal_mp%mca_frz(i,j,k) = 0.
                Removal_mp%mca_liq(i,j,k) =     &
                        -1.0*Don_mca_tend%qtnd(i,j,k)*Input_mp%pmass(i,j,k)
              end do
            endif
          end do
        end do
      endif

!---------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    just obtained from moist convective adjustment. currently there
!    is no tracer transport by this process, so qtr will be 0.0 for all
!    tracers.
!---------------------------------------------------------------------
      nn = 1
      do n=1, num_prog_tracers
        if (tracers_in_donner(n)) then
          Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                                Input_don%qtr(:,:,:,nn)
          nn = nn + 1
        endif
      end do

!-----------------------------------------------------------------------
!    turn off the donner mca clock.
!-----------------------------------------------------------------------
      call mpp_clock_end (donner_mca_clock)

!-----------------------------------------------------------------------


end subroutine donner_mca_driver 



!########################################################################

subroutine output_donner_diagnostics ( is, js, Input_mp, Conv_results,    &
                   Moist_clouds_block, Input_don, Output_don,  C2ls_mp,   &
                                                  Don_tend, Don_mca_tend)

!-----------------------------------------------------------------------
!    subroutine output_donner_diagnostics outputs various netcdf 
!    diagnostics that are associated with donner deep convection.
!-----------------------------------------------------------------------
                      
!--------------------------------------------------------------------
integer,                            intent(in)    :: is, js
type(mp_input_type),                intent(inout) :: Input_mp
type(conv_results_type),            intent(in)    :: Conv_results
type(clouds_from_moist_block_type), intent(inout) :: Moist_clouds_block
type(donner_input_type),            intent(inout) :: Input_don
type(conv_output_type),             intent(inout) :: Output_don
type(mp_conv2ls_type),              intent(in)    :: C2ls_mp
type(conv_tendency_type),           intent(inout) :: Don_tend, Don_mca_tend
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Moist_clouds_block 
!               derived type used to transfer cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    Input_don  donner_input_type variable containing input
!               fields used by donner_deep_mod
!    Output_don conv_output_type variable containing output
!               fields from donner_deep_mod
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Don_tend   conv_tendency_type variable containing tendency
!               output from donner convection
!    Don_mca_tend  
!               conv_tendency_type variable containing tendency
!               output from  the mca component of donner convection
!-----------------------------------------------------------------------

      logical, dimension(size(Input_mp%t,1),size(Input_mp%t,2)) ::    &
                                                     ltemp
      real, dimension(size(Don_tend%ttnd,1),    &
                                     size(Don_tend%ttnd,2)) :: temp_2d

      logical :: used
      integer :: ix, jx, kx
      integer :: k, n

!----------------------------------------------------------------------
!   ltemp         temporary logical array
!   temp_2d       temporary real array
!   used          logical used to indicate data has been received by
!                 diag_manager_mod
!   ix, jx, kx    physics window dimensions
!   k, n          do loop indices
!----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Don_tend%ttnd, 1)
      jx = size(Don_tend%ttnd, 2)
      kx = size(Don_tend%ttnd, 3)

!-----------------------------------------------------------------------
!    output scaling factors which were applied to donner tendencies to
!    preserve realizable water quantities. the difference between scale
!    and scale_REV reflects the absence of scaling where no conservation
!    is possible.
!-----------------------------------------------------------------------
      used = send_data (id_scale_donner, Output_don%scale,   &
                                                             Time, is, js )
      used = send_data (id_scale_donner_REV, Output_don%scale_REV, &
                                                             Time, is, js )

!--------------------------------------------------------------------
!    output diagnostics for the time tendencies of temperature, vapor 
!    specific humidity and large scale cloud fields, and various precip 
!    and mass flux diagnostics due to donner deep convection.
!--------------------------------------------------------------------
      used = send_data (id_tdt_deep_donner, Don_tend%ttnd, Time, is, js, 1)
      used = send_data (id_qdt_deep_donner, Don_tend%qtnd, Time, is, js, 1)
      used = send_data (id_qadt_deep_donner, Don_tend%qatnd,   &
                                                        Time, is, js, 1)
      used = send_data (id_qldt_deep_donner, Don_tend%qltnd,    &
                                                        Time, is, js, 1)
      used = send_data (id_qidt_deep_donner, Don_tend%qitnd,    &
                                                        Time, is, js, 1)

      used = send_data (id_mc_donner, Conv_results%mc_donner,   &
                                                        Time, is, js, 1)
      used = send_data (id_mc_donner_half, Conv_results%mc_donner_half,   &
                                                        Time, is, js, 1 )
      used = send_data (id_m_cdet_donner, Conv_results%donner_det_mflux,  &
                                                        Time,  is, js, 1 )
      used = send_data (id_m_cellup, Conv_results%donner_mflux,     &
                                                        Time, is, js, 1 )
      used = send_data (id_snow_deep_donner, Don_tend%snow, Time, is, js)
      used = send_data (id_prec_deep_donner,    &
                         Don_tend%rain + Don_tend%snow, Time, is, js )
      used = send_data (id_prec1_deep_donner,   &
                          Output_don%precip_adjustment, Time, is, js,   &
                                   mask = Output_don%precip_returned > 0.0)
      used = send_data (id_precret_deep_donner,  &
                            Output_don%precip_returned, Time, is, js)  
      if (do_donner_mca) then
        used = send_data (id_don_precip, Don_tend%rain + Don_tend%snow +  &
                                  Don_mca_tend%rain + Don_mca_tend%snow, &
                                                             Time, is, js)
        if (id_don_freq > 0) then
          ltemp = Don_tend%rain > 0. .or. Don_tend%snow > 0.0 .or. &
                  Don_mca_tend%rain > 0. .or. Don_mca_tend%snow > 0.0
          where (ltemp) 
            temp_2d = 1.
          elsewhere
            temp_2d = 0.
          end where
          used = send_data (id_don_freq, temp_2d, Time, is, js)
        endif
      else
        used = send_data (id_don_precip, Don_tend%rain + Don_tend%snow,   &
                                                             Time, is, js)
        if (id_don_freq > 0) then
          ltemp = Don_tend%rain > 0. .or. Don_tend%snow > 0.0 
          where (ltemp) 
            temp_2d = 1.
          elsewhere
            temp_2d = 0.
          end where
          used = send_data (id_don_freq, temp_2d, Time, is, js)
        endif
      endif

!------------------------------------------------------------------------
!    if donner conservation checks have been done, output various
!    diagnostics describing the results. 
!------------------------------------------------------------------------
      if (do_donner_conservation_checks) then
        used = send_data (id_enth_donner_col2, -hlv*Don_tend%rain,    &
                                                            Time, is, js)
        used = send_data (id_enth_donner_col3, -hls*Don_tend%snow,    &
                                                            Time, is, js)
        if (id_enth_donner_col4 > 0)   &
                     call column_diag(id_enth_donner_col4, is, js, Time, &
                             Don_tend%ttnd(:,:,:), CP_AIR, Input_mp%pmass)
        if (id_enth_donner_col5 > 0)    &
                     call column_diag(id_enth_donner_col5, is, js, Time, &
                             Output_don%delta_ql(:,:,:), -HLV*dtinv,   &
                             Output_don%delta_qi(:,:,:), -HLS*dtinv,   &
                                                           Input_mp%pmass)
        if (id_enth_donner_col6 > 0)     &
                     call column_diag(id_enth_donner_col6, is, js, Time, &
                                 Output_don%ttnd_adjustment, CP_AIR,   &
                                                           Input_mp%pmass)
        used = send_data (id_enth_donner_col7, Output_don%adjust_frac,  &
                                                            Time, is, js)
       
!------------------------------------------------------------------------
!    compute and output column enthalpy change due to donner deep 
!    convection.
!------------------------------------------------------------------------
        temp_2d = 0.
        do k=1,kx
          temp_2d(:,:) = temp_2d(:,:)   + &
             (-HLV*Output_don%liquid_precip(:,:,k)/seconds_per_day -  &
               hls*Output_don%frozen_precip(:,:,k)/seconds_per_day  + &
               CP_AIR*Don_tend%ttnd(:,:,k)  -  &
              (HLV*Don_tend%qltnd(:,:,k) + HLS*Don_tend%qitnd(:,:,k)))*   &
                                                     Input_mp%pmass(:,:,k)
        end do
        used = send_data (id_enth_donner_col, temp_2d, Time, is, js)

!------------------------------------------------------------------------
!    compute and output column water change due to donner deep convection.
!------------------------------------------------------------------------
        if (id_wat_donner_col > 0) then
          temp_2d = Don_tend%rain + Don_tend%snow
          call column_diag (id_wat_donner_col, is, js, Time,    &
                            Don_tend%qtnd, 1.0, Output_don%delta_ql,   &
                            dtinv, Output_don%delta_qi, dtinv, &
                                                   Input_mp%pmass, temp_2d)
        endif
      endif ! (donner_conservation_checks)

!------------------------------------------------------------------------
!    output additional diagnostics related to the clouds associated with
!    donner convection.
!------------------------------------------------------------------------
      used = send_data (id_cell_cld_frac,   &
                     Moist_clouds_block%cloud_data(i_cell)%cloud_area, &
                                                         Time, is, js, 1 )
      used = send_data (id_meso_cld_frac,   &
                     Moist_clouds_block%cloud_data(i_meso)%cloud_area, &
                                                         Time, is, js, 1)
      used = send_data (id_donner_humidity_area,    &
                     C2ls_mp%donner_humidity_area(:,:,:), Time, is, js, 1 )


      if (doing_prog_clouds) then
        if (do_ice_num .and. detrain_ice_num) then
          used = send_data (id_qnidt_deep_donner, Don_tend%qnitnd,   &
                                                          Time, is, js, 1)
        endif  

!-------------------------------------------------------------------------
!    detrain liquid droplets if desired. the original code had a bug which
!    may be preserved for test purposes with the remain_detrain_bug nml
!    variable. assume 10 micron mean volume radius for detrained droplets. 
!    Modify the particle number and particle number tendency from physics 
!    to account for this detrainment. output a diagnostic if desired.
!-------------------------------------------------------------------------
        if (do_liq_num .and. detrain_liq_num) then
          used = send_data (id_qndt_deep_donner,   &
                                        Don_tend%qntnd, Time, is, js, 1)
        endif
      endif  ! doing_prog_clouds

!-----------------------------------------------------------------------
!    output diagnostics associated with the donner mca component.
!-----------------------------------------------------------------------
      if (do_donner_mca) then

!--------------------------------------------------------------------
!    output the time tendencies of temperature, vapor specific humid-
!    ity, precipitation and snow due to the moist convective 
!    adjustment pass of the donner parameterization.
!--------------------------------------------------------------------
        used = send_data (id_tdt_mca_donner, Don_mca_tend%ttnd,   &
                                                         Time, is, js, 1)
        used = send_data (id_qdt_mca_donner, Don_mca_tend%qtnd,   &
                                                         Time, is, js, 1)
        used = send_data (id_prec_mca_donner,    &
                        Don_mca_tend%rain+Don_mca_tend%snow, Time, is, js)
        used = send_data (id_snow_mca_donner, Don_mca_tend%snow,    &
                                                          Time, is, js)

!------------------------------------------------------------------------
!    output the column imbalances of enthalpy and water resulting from the
!    mca component of donner convection. 
!------------------------------------------------------------------------
        if (id_enth_mca_donner_col > 0) then
          temp_2d = -HLV*Don_mca_tend%rain -HLS*Don_mca_tend%snow
          call column_diag(id_enth_mca_donner_col, is, js, Time,   &
                        Don_mca_tend%ttnd, CP_AIR, Input_mp%pmass, temp_2d)
        endif

        if (id_wat_mca_donner_col > 0) then
          temp_2d = Don_mca_tend%rain + Don_mca_tend%snow
          call column_diag(id_wat_mca_donner_col, is, js, Time,   &
                          Don_mca_tend%qtnd, 1.0,  Input_mp%pmass, temp_2d)
        endif

!--------------------------------------------------------------------
!    output the time tendencies of tracer and of column tracer 
!    due to the moist convective adjustment pass of the donner 
!    parameterization. currently moist convective adjustment does not
!    affect the tracer fields, so these fields are always 0.0.
!--------------------------------------------------------------------
        do n=1,num_donner_tracers
          if ( id_tracerdt_mcadon(n) > 0 ) &
            used = send_data(id_tracerdt_mcadon(n),   &
                                 Input_don%qtr(:,:,:,n), Time, is, js, 1 )
          if (id_tracerdt_mcadon_col(n) > 0 )  &
              call column_diag(id_tracerdt_mcadon_col(n), is, js, Time, &
                               Input_don%qtr(:,:,:,n), 1.0, Input_mp%pmass)
        enddo

      endif  ! (do_donner_mca)

!-----------------------------------------------------------------------


end subroutine output_donner_diagnostics



!#######################################################################

subroutine donner_dealloc (Input_don, Output_don, Don_tend, &
                                                      Don_mca_tend) 

!-------------------------------------------------------------------
!    subroutine donner_dealloc deallocates the components of the 
!    derived type variables rsident in subroutine donner_driver.
!-------------------------------------------------------------------

type(donner_input_type),  intent(inout) :: Input_don
type(conv_output_type),   intent(inout) :: Output_don
type(conv_tendency_type), intent(inout) :: Don_tend, Don_mca_tend

!--------------------------------------------------------------------
!    Input_don  donner_input_type variable containing input
!               fields used by donner_deep_mod
!    Output_don conv_output_type variable containing output
!               fields from donner_deep_mod
!    Don_tend   conv_tendency_type variable containing tendency
!               output from donner convection
!    Don_mca_tend  
!               conv_tendency_type variable containing tendency
!               output from  the mca component of donner convection
!-----------------------------------------------------------------------

!-------------------------------------------------------------------
!    deallocate the components of Input_don.
!-------------------------------------------------------------------
      deallocate (Input_don%rin)
      deallocate (Input_don%sfc_sh_flux)
      deallocate (Input_don%sfc_vapor_flux)
      deallocate (Input_don%tr_flux)
      deallocate (Input_don%ke_bl)
      deallocate (Input_don%maxTe_launch_level)
      deallocate (Input_don%qtr)
      deallocate (Input_don%qlin)
      deallocate (Input_don%qiin)
      deallocate (Input_don%qain)
      deallocate (Input_don%nllin)
      deallocate (Input_don%nilin)

!-------------------------------------------------------------------
!    deallocate the components of Output_don.
!-------------------------------------------------------------------
      deallocate (Output_don%delta_temp)
      deallocate (Output_don%delta_vapor)
      deallocate (Output_don%delta_q   )
      deallocate (Output_don%delta_ql  )
      deallocate (Output_don%delta_qi  )
      deallocate (Output_don%delta_qa  )
      deallocate (Output_don%delta_qn  )
      deallocate (Output_don%delta_qni )
      deallocate (Output_don%ttnd_adjustment)
      deallocate (Output_don%liquid_precip  )
      deallocate (Output_don%frozen_precip  )
      deallocate (Output_don%lheat_precip   )
      deallocate (Output_don%vert_motion    )
      deallocate (Output_don%total_precip   )
      deallocate (Output_don%scale          )
      deallocate (Output_don%scale_REV   )
      deallocate (Output_don%precip_adjustment)
      deallocate (Output_don%precip_returned  )
      deallocate (Output_don%adjust_frac      )
      deallocate (Output_don%donner_tracer    )

!-------------------------------------------------------------------
!    deallocate the components of Don_tend.  
!-------------------------------------------------------------------
      deallocate (Don_tend%delta_q)
      deallocate (Don_tend%rain)
      deallocate (Don_tend%snow)
      deallocate (Don_tend%ttnd)
      deallocate (Don_tend%qtnd)
      deallocate (Don_tend%qtr    )
      if (doing_prog_clouds) then
        deallocate (Don_tend%qltnd)
        deallocate (Don_tend%qitnd)
        deallocate (Don_tend%qatnd)
        deallocate (Don_tend%qntnd)
        deallocate (Don_tend%qnitnd)
      endif

!-------------------------------------------------------------------
!    deallocate the components of Don_mca_tend.  
!-------------------------------------------------------------------
      if (do_donner_mca) then
        deallocate (Don_mca_tend%rain)
        deallocate (Don_mca_tend%snow)
        deallocate (Don_mca_tend%ttnd)
        deallocate (Don_mca_tend%qtnd)
        deallocate (Don_mca_tend%qtr    )
      endif

!--------------------------------------------------------------------


end subroutine donner_dealloc 



!#######################################################################



!*******************************************************************
!
!                  PRIVATE, DRY ADJUSTMENT-RELATED SUBROUTINES
!
!*******************************************************************


!######################################################################

subroutine dca_driver (is, js, Input_mp, Output_mp, Tend_mp)

!---------------------------------------------------------------------
!    subroutine dca_driver prepares for, calls, and handles the output from
!    the dry convective adjustment parameterization.
!---------------------------------------------------------------------

integer,                intent(in)    :: is, js
type(mp_input_type),    intent(inout) :: Input_mp
type(mp_output_type),   intent(inout) :: Output_mp
type(mp_tendency_type), intent(inout) :: Tend_mp

!----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!---------------------------------------------------------------------

      real, dimension(size(Input_mp%t,1),size(Input_mp%t,2),   &
                                   size(Input_mp%t,3)) ::  delta_temp
      type(conv_tendency_type) :: Dca_tend
      logical :: used
      integer :: ix, jx, kx

!---------------------------------------------------------------------
!   delta_temp    
!   Dca_tend      conv_tendency_type variable containing tendency
!                 output from dry convective adjustment parameterization
!   used          logical used to indicate data has been received by
!                 diag_manager_mod
!   ix, jx, kx    physics window dimensions
!---------------------------------------------------------------------

!---------------------------------------------------------------------
!    activate dca_clock.
!---------------------------------------------------------------------
      call mpp_clock_begin (dca_clock)

!--------------------------------------------------------------------
!     define local array dimensions.
!--------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 

!--------------------------------------------------------------------
!     allocate and initialize tendency array.
!--------------------------------------------------------------------
      allocate (Dca_tend%ttnd(ix, jx, kx))
      Dca_tend%ttnd = 0.

!---------------------------------------------------------------------
!    call subroutine dry_adj to obtain the temperature tendencies which 
!    must be applied to adjust each column to a non-superadiabatic lapse 
!    rate. 
!---------------------------------------------------------------------
      call dry_adj (Input_mp%tin, Input_mp%pfull, Input_mp%phalf,   &
                                                              delta_temp)

!-------------------------------------------------------------------
!    add the temperature change due to dry adjustment to the current
!    temperature. convert the temperature change to a heating rate.
!-------------------------------------------------------------------
      Input_mp%tin  = Input_mp%tin + delta_temp
      Dca_tend%ttnd  = delta_temp*dtinv

!---------------------------------------------------------------------
!    output the temperature tendency from dry adjustment, if desired.
!---------------------------------------------------------------------
      used = send_data (id_tdt_dadj, Dca_tend%ttnd, Time, is, js, 1 )

!----------------------------------------------------------------------
!    call update_outputs to update the arrays which will return the
!    convective tendencies to moist_processes.
!----------------------------------------------------------------------
      call update_outputs (Dca_tend, Output_mp, Tend_mp)

!----------------------------------------------------------------------
!    deallocate local arrays and turn off the dca clock.
!----------------------------------------------------------------------
      deallocate (Dca_tend%ttnd)
      call mpp_clock_end   (dca_clock)

!---------------------------------------------------------------------


end subroutine dca_driver



!######################################################################


!*******************************************************************
!
!               PRIVATE, BETTS-MILLER-RELATED SUBROUTINES
!
!*******************************************************************

!#######################################################################

subroutine betts_miller_driver (is, js, Input_mp, Output_mp, Tend_mp)  

!------------------------------------------------------------------
!  subroutine betts_miller_driver prepares for, calls, and handles the 
!  output from the three flavors of the betts-miller convective 
!  parameterization.
!------------------------------------------------------------------

integer,                intent(in)    :: is, js
type(mp_input_type),    intent(inout) :: Input_mp
type(mp_output_type),   intent(inout) :: Output_mp
type(mp_tendency_type), intent(inout) :: Tend_mp
                                          
!----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!---------------------------------------------------------------------

      real, dimension(size(Input_mp%qin,1),   &
                      size(Input_mp%qin,2),  size(Input_mp%qin,3)) ::  &
                                             RH, t_ref, q_ref, massflux
      real, dimension(size(Input_mp%qin,1), size(Input_mp%qin,2)) ::    &
                          bmflag, klzbs, invtaubmt, invtaubmq, cape, cin
      type(conv_tendency_type) :: BM_tend
      logical :: used, alpha
      integer :: ix, jx, kx

!---------------------------------------------------------------------
!   RH            relative humidity
!   t_ref         reference temperature profile used with Betts-Miller
!                 convection
!   q_ref         reference specific humidity p[rofile used with
!                 Betts-Miller convection
!   massflux      mass flux used to calculate the humidity adjustment
!   bmflag        bmflag indicates the degree of convection in the 
!                 column
!                 bmflag = 0. is no cape, no convection
!                 bmflag = 1. is shallow conv, no precipitationo
!                 bmflag = 2. is deep convection
!   klzbs         model grid level of zero buoyancy 
!   invtaubmt     temperature relaxation timescale
!   invtaubmq     humidity relaxation timescale
!   cape          convective available potential energy
!   cin           convective inhibition
!   BM_tend       conv_tendency_type variable containing tendency
!                 output from betts-miller parameterization
!   used          logical used to indicate data has been received by
!                 diag_manager_mod
!   alpha         logical indicating whether do_rh_clouds is .true.
!   ix, jx, kx    physics window dimesnsions
!---------------------------------------------------------------------

!---------------------------------------------------------------------
!    activate bm_clock.
!---------------------------------------------------------------------
      call mpp_clock_begin (bm_clock)

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 

!--------------------------------------------------------------------
!    allocate and initialize the needed components of a
!    conv_tendency_type array.
!--------------------------------------------------------------------
      allocate (BM_tend%rain(ix, jx))  
      allocate (BM_tend%snow(ix, jx)) 
      allocate (BM_tend%ttnd(ix, jx, kx))
      allocate (BM_tend%qtnd(ix, jx, kx))
      BM_tend%rain = 0.
      BM_tend%snow = 0.
      BM_tend%ttnd = 0.
      BM_tend%qtnd = 0.

!--------------------------------------------------------------------
!    initialize local arrays.
!--------------------------------------------------------------------
      t_ref = 0.
      q_ref = 0.

!----------------------------------------------------------------------
!    call appropriate interface dependent on flavor of Betts-Miller which
!    has been selected.
!----------------------------------------------------------------------
      if (LBM) then

!----------------------------------------------------------------------
!    betts-miller cumulus param scheme
!----------------------------------------------------------------------
        call betts_miller     &
               (dt, Input_mp%tin, Input_mp%qin, Input_mp%pfull, &
                     Input_mp%phalf, Input_mp%coldT, BM_tend%rain,   &
                        BM_tend%snow, BM_tend%ttnd, BM_tend%qtnd,   &
                           q_ref, bmflag, klzbs, cape, cin, t_ref, & 
                                                    invtaubmt, invtaubmq)
      endif

      if (LBMmass) then

!----------------------------------------------------------------------
!    betts-miller-style massflux cumulus param scheme
!----------------------------------------------------------------------
        call bm_massflux    &
               (dt, Input_mp%tin, Input_mp%qin, Input_mp%pfull,   &
                  Input_mp%phalf, Input_mp%coldT, BM_tend%rain,    &
                    BM_tend%snow, BM_tend%ttnd, BM_tend%qtnd, q_ref,   &
                                          bmflag, klzbs, t_ref, massflux)

      endif

      if (LBMomp) then
!----------------------------------------------------------------------
!    olivier's betts-miller cumulus param scheme
!----------------------------------------------------------------------
        call bm_omp    &
               (dt, Input_mp%tin, Input_mp%qin, Input_mp%pfull,  &
                 Input_mp%phalf, Input_mp%coldT, BM_tend%rain,   &
                    BM_tend%snow, BM_tend%ttnd, BM_tend%qtnd, q_ref,  &
                                                   bmflag, klzbs, t_ref)
      endif

!----------------------------------------------------------------------
!    update input values and compute tendency.
!----------------------------------------------------------------------
      Input_mp%tin = Input_mp%tin + BM_tend%ttnd
      Input_mp%qin = Input_mp%qin + BM_tend%qtnd

      BM_tend%ttnd = BM_tend%ttnd*dtinv
      BM_tend%qtnd = BM_tend%qtnd*dtinv
      BM_tend%rain= BM_tend%rain*dtinv
      BM_tend%snow= BM_tend%snow*dtinv

!-------------------------------------------------------------------------
!    compute rh clouds if they are active with betts-miller. first 
!    calculate the relative humidity, then pass it to rh_clouds_mod to be
!    stored till needed.
!-------------------------------------------------------------------------
      if (do_rh_clouds_BM) then
        alpha = do_rh_clouds()
        if (alpha) then
          call rh_calc   &
               (Input_mp%pfull, Input_mp%tin, Input_mp%qin, RH, do_simple)
          call rh_clouds_sum (is, js, RH) 
        else
          call error_mesg ('convection_driver', &
                 'rh_clouds_mod is being used without initialization', &
                                                               FATAL)
        endif
      end if

!-----------------------------------------------------------------------
!    save desired betts-miller diagnostics.
!-----------------------------------------------------------------------
      used = send_data (id_tref, t_ref, Time, is, js, 1 )
      used = send_data (id_qref, q_ref, Time, is, js, 1 )
      used = send_data (id_bmflag, bmflag, Time, is, js)
      used = send_data (id_klzbs, klzbs, Time, is, js)
      if (do_bm) then
        used = send_data (id_invtaubmt, invtaubmt, Time, is, js)
        used = send_data (id_invtaubmq, invtaubmq, Time, is, js)
      endif
      if (do_bmmass) then
        used = send_data (id_massflux, massflux, Time, is, js, 1)
      endif

!----------------------------------------------------------------------
!    call update_outputs to update the arrays which will return the
!    convective tendencies to moist_processes.
!----------------------------------------------------------------------
      call update_outputs (BM_tend, Output_mp, Tend_mp)

!-----------------------------------------------------------------------
!    preserve an error / bug in the warsaw code. diagnostic output changes
!    for the post-warsaw case, reflecting the bugfix.
!-----------------------------------------------------------------------
      if (reproduce_AM4) then
        Tend_mp%ttnd_conv = 0.
        Tend_mp%qtnd_conv = 0.
      endif

!----------------------------------------------------------------------
!    deallocate components of conv_tendency_type which were allocated
!    in this subroutine.
!----------------------------------------------------------------------
      deallocate (BM_tend%rain)
      deallocate (BM_tend%snow)
      deallocate (BM_tend%ttnd)
      deallocate (BM_tend%qtnd)

!---------------------------------------------------------------------
!    turn off the betts-miller clock.
!---------------------------------------------------------------------
      call mpp_clock_end (bm_clock)

!---------------------------------------------------------------------


end subroutine betts_miller_driver



!#######################################################################


!*******************************************************************
!
!              PRIVATE, MCA-RELATED SUBROUTINES
!
!*******************************************************************


subroutine mca_driver  (is, js, Input_mp, Output_mp, Tend_mp)

!-----------------------------------------------------------------------
!    subroutine mca_driver prepares for, calls, and handles the output from
!    the moist convective adjustment parameterization.
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
integer,                intent(in)    :: is, js
type(mp_input_type),    intent(inout) :: Input_mp
type(mp_output_type),   intent(inout) :: Output_mp
type(mp_tendency_type), intent(inout) :: Tend_mp

!----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!---------------------------------------------------------------------

      real, dimension(size(Output_mp%rdt,1), size(Output_mp%rdt,2),&
                       size(Output_mp%rdt,3), num_mca_tracers) :: trcr
      type(conv_tendency_type) :: Mca_tend
      integer :: ix, jx, kx
      integer :: nn, n

!-----------------------------------------------------------------------
!   trcr           set of tracers transported by moist convective
!                  adjustment
!   Mca_tend       conv_tendency_type variable containing tendency
!                  output from moist convective adjustment parameterization
!   ix, jx, kx     physics window dimensions
!   n              do loop index
!   nn             counter
!-----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    turn on the mca clock.
!-----------------------------------------------------------------------
      call mpp_clock_begin (mca_clock)

!-------------------------------------------------------------------
!    define the physics window dimensions.
!-------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 

!-------------------------------------------------------------------
!    allocate and initialize the components of the derived type variable
!    Mca_tend.
!-------------------------------------------------------------------
      allocate (Mca_tend%ttnd(ix, jx, kx))
      allocate (Mca_tend%qtnd(ix, jx, kx))
      allocate (Mca_tend%qltnd(ix, jx, kx))
      allocate (Mca_tend%qitnd(ix, jx, kx))
      allocate (Mca_tend%qatnd(ix, jx, kx))
      allocate (Mca_tend%rain (ix, jx))
      allocate (Mca_tend%snow (ix, jx))
      allocate (Mca_tend%qtr  (ix, jx, kx, num_mca_tracers))

      Mca_tend% ttnd  = 0.
      Mca_tend% qtnd  = 0.
      Mca_tend% qltnd = 0.
      Mca_tend% qitnd = 0.
      Mca_tend% qatnd = 0.
      Mca_tend% rain  = 0.
      Mca_tend% snow  = 0.
      Mca_tend% qtr   = 0.

!---------------------------------------------------------------------
!    check each active tracer to find any that are to be transported 
!    by moist convective adjustment and fill the trcr array with
!    these fields.
!---------------------------------------------------------------------
      nn = 1
      do n=1, num_prog_tracers
        if (tracers_in_mca(n)) then
          trcr(:,:,:,nn) = Input_mp%tracer(:,:,:,n)
          nn = nn + 1
        endif
      end do

!---------------------------------------------------------------------
!    call subroutine moist_conv to obtain the temperature, moisture
!    precipitation and tracer tendencies due to the moist convective
!    adjustment parameterization. currently there is no tracer tendency
!    due to this parameterization.
!++++yim Should also account for change in qn dut to moist convective 
!    adjustment.
!---------------------------------------------------------------------
      if (doing_prog_clouds) then
        call moist_conv (Input_mp%tin, Input_mp%qin, Input_mp%pfull,  &
                         Input_mp%phalf, Input_mp%coldT, Mca_tend%ttnd,   &
                         Mca_tend%qtnd, Mca_tend%rain, Mca_tend%snow, &
                         dtinv, Time, is, js, trcr, Mca_tend%qtr,     &
                         ql=INput_mp%tracer(:,:,:,nql),  &
                         qi=Input_mp%tracer(:,:,:,nqi),     &
                         cf=Input_mp%tracer(:,:,:,nqa),  &
                         qldel=Mca_tend%qltnd,   &
                         qidel=Mca_tend%qitnd,  &
                         cfdel=Mca_tend%qatnd)
      else
        call moist_conv (Input_mp%tin, Input_mp%qin, Input_mp%pfull,   &
                         Input_mp%phalf, Input_mp%coldT, Mca_tend%ttnd, &
                         Mca_tend%qtnd, Mca_tend%rain, Mca_tend%snow,  &
                         dtinv, Time, is, js, trcr, Mca_tend%qtr)
      endif

!---------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    just obtained from moist convective adjustment. currently there
!    is no tracer transport by this process.
!    NOTE : the stratcloud tracers are updated within moist_conv.
!---------------------------------------------------------------------
      nn = 1
      do n=1, num_prog_tracers
        if (tracers_in_mca(n)) then
          Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                                 Mca_tend%qtr(:,:,:,nn)
          nn = nn + 1
        endif
      end do

!---------------------------------------------------------------------
!    call update_outputs to update the arrays which will return the
!    convective tendencies to moist_processes.
!----------------------------------------------------------------------
      call update_outputs (Mca_tend, Output_mp, Tend_mp)

!---------------------------------------------------------------------
!    deallocate the components of Mca_tend.
!---------------------------------------------------------------------
      deallocate (Mca_tend%ttnd)
      deallocate (Mca_tend%qtnd)
      deallocate (Mca_tend%qltnd)
      deallocate (Mca_tend%qitnd)
      deallocate (Mca_tend%qatnd)
      deallocate (Mca_tend%rain )
      deallocate (Mca_tend%snow )
      deallocate (Mca_tend%qtr  )

!----------------------------------------------------------------------
!    turn off the mca clock.
!----------------------------------------------------------------------
      call mpp_clock_end (mca_clock)

!--------------------------------------------------------------------


end subroutine mca_driver



!#######################################################################

!*******************************************************************
!
!                     PRIVATE, UW-THEN-DONNER RELATED SUBROUTINES
!
!*******************************************************************

subroutine uw_then_donner_driver &
                (is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                       Output_mp, Tend_mp, Conv_results, Removal_mp, &
                                              Moist_clouds_block, C2ls_mp)

!-----------------------------------------------------------------------
!    subroutine uw_then_donner_driver handles the case when uw convection 
!    is calculated first, followed by calculation of donner convection.
!-----------------------------------------------------------------------

integer,                             intent(in)    :: is, ie, js, je
type(mp_input_type),                 intent(inout) :: Input_mp
type(aerosol_type),                  intent(in)    :: Aerosol
type(phys_mp_exch_type),             intent(inout) :: Phys_mp_exch
type(mp_output_type),                intent(inout) :: Output_mp
type(mp_tendency_type),              intent(inout) :: Tend_mp
type(conv_results_type),             intent(inout) :: Conv_results
type(mp_removal_type),               intent(inout) :: Removal_mp
type(clouds_from_moist_block_type),  intent(inout) :: Moist_clouds_block
type(mp_conv2ls_type),               intent(inout) :: C2ls_mp

!-----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    ie,je      ending i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Aerosol    derived type containing model aerosol fields to be input
!               to model convective schemes
!    Phys_mp_exch
!               derived type used to transfer data between physics_driver
!               and convection_driver via moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Moist_clouds_block 
!               derived type used to transfer cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!-----------------------------------------------------------------------

      type(conv_tendency_type) ::   Uw_tend
      type(conv_output_type)   ::   Output_uw

!------------------------------------------------------------------------
!    Uw_tend      conv_tendency_type variable containing tendency
!                 output from uw convection
!    Output_uw    conv_output_type variable containing output
!                 fields from uw convection
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
!    use the nml variable use_updated_profiles_for_donner to determine
!    execution path through this module. 
!-----------------------------------------------------------------------
      if (use_updated_profiles_for_donner) then  ! ORIG4

!----------------------------------------------------------------------
!    if one is using profiles updated by uw convection as inputs to the
!    donner parameterization, call uw first (doing both parts of that 
!    calculation), followed by a call to donner convection.
!----------------------------------------------------------------------
        call mpp_clock_begin (uw_clock)
        call uw_conv_driver_part  &
                (is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                      Output_mp, Tend_mp, Conv_results, Removal_mp,     &
                           Moist_clouds_block%cloud_data(i_shallow),    &
                                      Uw_tend, Output_uw,  .true., .true.)
        call mpp_clock_end (uw_clock)

        call donner_driver ( is, ie, js, je, Input_mp,             &
                              Moist_clouds_block, Conv_results,     &
                                 C2ls_mp, Removal_mp, Tend_mp, Output_mp)

!----------------------------------------------------------------------
!    if not using updated fields for donner, execute the following.  
!    this path will also reproduce results obtained using base warsaw
!    code if nml variable reproduce_AM4 is set to .true., using
!    some inconsistent values in the cmt calculation;  if
!    reproduce_AM4 is set .false., then consistent (unupdated)
!    values will be used in the cmt and other calculations.
!----------------------------------------------------------------------
      else    ! ORIG2 and ORIG5

!---------------------------------------------------------------------
!    call uw_conv_driver_part to execute the first part of the uw conv
!    calculation.
!---------------------------------------------------------------------
        call mpp_clock_begin (uw_clock)
        call uw_conv_driver_part    &
                ( is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                      Output_mp, Tend_mp, Conv_results, Removal_mp,     &
                           Moist_clouds_block%cloud_data(i_shallow),    &
                                     Uw_tend, Output_uw,  .true., .false.)
        call mpp_clock_end (uw_clock)

!---------------------------------------------------------------------
!    call donner_driver to execute the donner_deep parameterization.
!---------------------------------------------------------------------
        call donner_driver ( is, ie, js, je, Input_mp,             &
                             Moist_clouds_block, Conv_results,          &
                             C2ls_mp, Removal_mp, Tend_mp, Output_mp)

!---------------------------------------------------------------------
!    call uw_conv_driver_part to execute the second part of the uw conv
!    calculation.
!---------------------------------------------------------------------
        call mpp_clock_begin (uw_clock)
        call uw_conv_driver_part  &
                ( is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch,   &
                     Output_mp, Tend_mp, Conv_results, Removal_mp,     &
                           Moist_clouds_block%cloud_data(i_shallow),    &
                                 Uw_tend, Output_uw,  .false., .true.)
        call mpp_clock_end (uw_clock)
      endif

!----------------------------------------------------------------------


  end subroutine uw_then_donner_driver 



!#######################################################################

!*******************************************************************
!
!                     PRIVATE, UW-RELATED SUBROUTINES
!
!*******************************************************************

subroutine uw_conv_driver    &
              (is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch, &
              Output_mp, Tend_mp, Conv_results, Removal_mp, Cld_props)

!----------------------------------------------------------------------
!   subroutine uw_conv_driver prepares for and executes the uw convection
!   parameterization, and then processes its output appropriately. both
!   parts of uw_conv_driver_part are executed when called from this 
!   subroutine.
!----------------------------------------------------------------------

integer,                      intent(in)     :: is, ie, js, je
type(mp_input_type),          intent(inout)  :: Input_mp
type(aerosol_type),           intent(in)     :: Aerosol
type(phys_mp_exch_type),      intent(inout)  :: Phys_mp_exch
type(mp_output_type),         intent(inout)  :: Output_mp
type(mp_tendency_type),       intent(inout)  :: Tend_mp
type(conv_results_type),      intent(inout)  :: Conv_results
type(mp_removal_type),        intent(inout)  :: Removal_mp
type(cloud_scheme_data_type), intent(inout)  :: Cld_props

!---------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    ie,je      ending i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Aerosol    derived type containing model aerosol fields to be input
!               to model convective schemes
!    Phys_mp_exch
!               derived type used to transfer data between physics_driver
!               and convection_driver via moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Cld_props  derived type used to transfer uw cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!-----------------------------------------------------------------------

      type(conv_tendency_type) :: Uw_tend
      type(conv_output_type)   :: Output_uw

!------------------------------------------------------------------------
!    Uw_tend      conv_tendency_type variable containing tendency
!                 output from uw convection
!    Output_uw    conv_output_type variable containing output
!                 fields from uw convection
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
!    activate the uw clock.
!-----------------------------------------------------------------------
      call mpp_clock_begin (uw_clock)

!-----------------------------------------------------------------------
!    call uw_conv_driver_part, executing both parts of the driver.
!-----------------------------------------------------------------------
      call uw_conv_driver_part  &
              (is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch, &
              Output_mp, Tend_mp, Conv_results, Removal_mp, Cld_props, &
                                    Uw_tend, Output_uw, .true., .true.)

!----------------------------------------------------------------------
!    turn off the uw clock.
!----------------------------------------------------------------------
      call mpp_clock_end (uw_clock)

!------------------------------------------------------------------------


end subroutine uw_conv_driver



!########################################################################

subroutine uw_conv_driver_part    &
              (is, ie, js, je, Input_mp, Aerosol, Phys_mp_exch, &
              Output_mp, Tend_mp, Conv_results, Removal_mp, Cld_props, &
                           Uw_tend, Output_uw, do_segment1, do_segment2)

!-----------------------------------------------------------------------
integer,                        intent(in)    :: is, ie, js, je
type(mp_input_type),            intent(inout) :: Input_mp
type(aerosol_type),             intent(in)    :: Aerosol
type(phys_mp_exch_type),        intent(inout) :: Phys_mp_exch
type(mp_output_type),           intent(inout) :: Output_mp
type(mp_tendency_type),         intent(inout) :: Tend_mp
type(conv_results_type),        intent(inout) :: Conv_results
type(mp_removal_type),          intent(inout) :: Removal_mp
type(cloud_scheme_data_type),   intent(inout) :: Cld_props
type(conv_tendency_type),       intent(inout) :: Uw_tend
type(conv_output_type),         intent(inout) :: Output_uw
logical,                        intent(in)    :: do_segment1, do_segment2
                                           
!-----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    ie,je      ending i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Aerosol    derived type containing model aerosol fields to be input
!               to model convective schemes
!    Phys_mp_exch
!               derived type used to transfer data between physics_driver
!               and convection_driver via moist_processes
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    Removal_mp derived type used to transfer precipitation and tracer
!               removal fields between convection_driver and 
!               moist_processes
!    Cld_props  derived type used to transfer uw cloud data between 
!               atmos_model and convection_driver via physics_driver and
!               moist_processes
!    Uw_tend    conv_tendency_type variable containing tendency
!               output from uw convection
!    Output_uw  conv_output_type variable containing output
!               fields from uw convection
!    do_segment1
!               logical indicating if first part of uw_conv_driver is to
!               be executed
!    do_segment2
!               logical indicating if second part of uw_conv_driver is to
!               be executed
!-----------------------------------------------------------------------

      real, dimension(size(Input_mp%t,1), size(Input_mp%t,2),      &
                                         size(Input_mp%t,3))  :: targ, qarg
      real, dimension(size(Input_mp%t,1), size(Input_mp%t,2),      &
                         size(Input_mp%t,3), num_uw_tracers)  :: trcr
      real, dimension(size(Input_mp%t,1), size(Input_mp%t,2),      &
                         size(Input_mp%t,3),       &
                                   num_prog_tracers)          :: tracerarg
      integer :: ix, jx, kx
      logical :: used
      integer :: nt                           
      integer :: n                           
      integer :: nn

!---------------------------------------------------------------------
!   targ           temperature field passed to uw_conv
!   qarg           specific humidity field passed to uw_conv
!   trcr           set of tracers actually transported by uw_conv
!   tracerarg      tracer fields passed to uw_conv
!   ix, jx, kx     physics window dimensions
!   nt             number of prognostic tracers
!   n              do loop index
!   nn             counter
!----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define array dimensions and number of prognostic tracers.
!-----------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 
      nt = size(Output_mp%rdt,4)

!-----------------------------------------------------------------------
!    this first part is executed when do_segment1 = .true.. to reproduce
!    the warsaw results it is necessary to execute the first part, call 
!    donner, and then finish the uw execution (do_segment2 = .true.)
!-----------------------------------------------------------------------
      if (do_segment1) then

!----------------------------------------------------------------------
!    call uw_alloc to allocate the needed components of the local derived
!    type varaibles resident in this module.
!----------------------------------------------------------------------
        call uw_alloc (ix, jx, kx, Uw_tend, Output_uw)

!------------------------------------------------------------------------
!    define arguments to be used in uw convection calculation, either the
!    fields upon entry to convection, or the fields after having been
!    modified by another convective parameterization.
!------------------------------------------------------------------------
        if (use_updated_profiles_for_uw) then

!---------------------------------------------------------------------
!    if arguments are to be updated, update the tracer fields with 
!    tendencies due to donner convection and wet deposition by donner 
!    deep precipitation.
!---------------------------------------------------------------------
          do n=1,nt  
            if (.not. cloud_tracer(n)) then
              Input_mp%tracer(:,:,:,n) = Input_mp%tracer_orig(:,:,:,n) +  &
                                (Output_mp%rdt(:,:,:,n) -     &
                                         Output_mp%rdt_init(:,:,:,n)) *dt
            endif
          end do

!---------------------------------------------------------------------
!    define the t, q and tracer fields to be passed to uw convection.
!---------------------------------------------------------------------
          targ = Input_mp%tin
          qarg = Input_mp%qin
          tracerarg = Input_mp%tracer
        else
          targ = Input_mp%tin_orig
          qarg = Input_mp%qin_orig
          tracerarg = Input_mp%tracer_orig
        endif

!----------------------------------------------------------------------
!    if any tracers are to be transported by UW convection, check each
!    active tracer to find those to be transported and fill the 
!    trcr array with these fields.
!---------------------------------------------------------------------
        nn = 1
        do n=1, num_prog_tracers
          if (tracers_in_uw(n)) then
            trcr(:,:,:,nn) = tracerarg(:,:,:,n)
            nn = nn + 1
          endif
        end do

!-------------------------------------------------------------------------
!     call uw_conv to calculate the effects of shallow convection.
!-------------------------------------------------------------------------
        call uw_conv (is, js, Time, targ, qarg, Input_mp%uin,   &
                      Input_mp%vin, Input_mp%pfull, Input_mp%phalf,&
                      Input_mp% zfull, Input_mp%zhalf, tracerarg,   &
                      Input_mp%omega, dt, Input_mp%pblht, &
                      Input_mp%ustar, Input_mp%bstar, Input_mp%qstar,  &
                      Input_mp%land, Input_mp%coldT, Aerosol,   &
                      Input_mp%lat, Input_mp%lon, Input_mp%cush, &
                      Phys_mp_exch%tke, doing_prog_clouds,  &
                      Conv_results%conv_calc_completed,   &
                      Conv_results%available_cf_for_uw, Uw_tend%ttnd,    &
                      Uw_tend%qtnd, Uw_tend%qltnd, Uw_tend%qitnd, &
                      Uw_tend%qatnd, Uw_tend%qntnd,      &
                      Uw_tend%utnd, Uw_tend%vtnd, Uw_tend%rain, &
                      Uw_tend%snow, Conv_results%uw_mflux,   &
                      Removal_mp%liq_precflx, &
                      Removal_mp%ice_precflx, Cld_props%liquid_amt,   &
                      Cld_props%ice_amt, Cld_props%cloud_area,   &
                      Cld_props%droplet_number, trcr, Uw_tend%qtr,   &
                      Removal_mp%uw_wetdep, Input_mp%cbmf,    &
                      Phys_mp_exch%cgust)

!-------------------------------------------------------------------------
!    call detr_ice_num to calculate the ice number tendency due to 
!    detrainment, which is proportional to the ice mass.
!-------------------------------------------------------------------------
        if (do_ice_num .and. detrain_ice_num) then
          CALL detr_ice_num (targ, Uw_tend%qitnd(:,:,:),    &
                                                 Uw_tend%qnitnd(:,:,:) )
        end if
      endif ! (do_segment1)

!----------------------------------------------------------------------
!    the second segment is executed whe do_segment2 is .true..
!----------------------------------------------------------------------
      if (do_segment2) then

!---------------------------------------------------------------------
!    if desired, call define_and_apply_scale to compute any adjustment 
!    needed in order to preserve realizability for the water variables.
!---------------------------------------------------------------------
        if (do_limit_uw) then
          call define_and_apply_scale   &
              (Input_mp, Uw_tend, Output_uw, .false., .true., Uw_tend%qtr)
        else  
          Output_uw%scale = 1.0
        endif 

!-----------------------------------------------------------------------
!    call finalize_uw_outputs to define output fields, update input
!    fields as needed, and output uw-related diagnostics.
!-----------------------------------------------------------------------
        call finalize_uw_outputs (is, js, Input_mp, Uw_tend, Output_uw, &
                                                              Output_mp)

!-----------------------------------------------------------------------
!    call update_outputs to update the arrays which will return the
!    convective tendencies to moist_processes.
!-----------------------------------------------------------------------
        call update_outputs (Uw_tend, Output_mp, Tend_mp)

!----------------------------------------------------------------------
!    call uw_dealloc to deallocate the components of the derived type
!    variables Uw_tend and Output_uw.
!----------------------------------------------------------------------
        call uw_dealloc (Uw_tend, Output_uw)

!----------------------------------------------------------------------
!    end of segment2.
!----------------------------------------------------------------------
      endif ! (do_segment2)

!------------------------------------------------------------------------


end subroutine uw_conv_driver_part



!#####################################################################

subroutine uw_alloc (ix, jx, kx, Uw_tend, Output_uw)

!----------------------------------------------------------------------
!    subroutine uw_alloc allocates the needed components of the
!    conv_tendency_type and conv_output_type variables.
!----------------------------------------------------------------------
integer,                  intent(in)    :: ix, jx, kx
type(conv_tendency_type), intent(inout) :: Uw_tend
type(conv_output_type),   intent(inout) :: Output_uw

!------------------------------------------------------------------------
!    ix, jx, kx      physics window dimensions
!    Uw_tend         conv_tendency_type variable containing tendency
!                    output from uw convection
!    Output_uw       conv_output_type variable containing output
!                    fields from uw convection
!------------------------------------------------------------------------

!----------------------------------------------------------------------
!    allocate and initialize the needed components of Uw_tend.
!----------------------------------------------------------------------
      allocate (Uw_tend%delta_q   (ix, jx,kx))
      allocate (Uw_tend%rain      (ix, jx))
      allocate (Uw_tend%snow      (ix, jx))
      allocate (Uw_tend%ttnd      (ix, jx, kx))
      allocate (Uw_tend%qtnd      (ix, jx, kx))
      allocate (Uw_tend%utnd      (ix, jx, kx))
      allocate (Uw_tend%vtnd      (ix, jx, kx))
      allocate (Uw_tend%qltnd     (ix, jx, kx))
      allocate (Uw_tend%qitnd     (ix, jx, kx))
      allocate (Uw_tend%qatnd     (ix, jx, kx))
      allocate (Uw_tend%qntnd     (ix, jx, kx))
      allocate (Uw_tend%qnitnd    (ix, jx, kx))
      allocate (Uw_tend%qtr       (ix, jx, kx, num_uw_tracers))

      Uw_tend%delta_q  = 0.
      Uw_tend%rain     = 0.
      Uw_tend%snow     = 0.
      Uw_tend%ttnd     = 0.
      Uw_tend%qtnd     = 0.
      Uw_tend%utnd     = 0.
      Uw_tend%vtnd     = 0.
      Uw_tend%qltnd    = 0.
      Uw_tend%qitnd    = 0.
      Uw_tend%qatnd    = 0.
      Uw_tend%qntnd    = 0.
      Uw_tend%qnitnd   = 0.
      Uw_tend%qtr      = 0.

!----------------------------------------------------------------------
!    allocate and initialize the needed components of Output_uw.
!----------------------------------------------------------------------
      allocate (Output_uw%liquid_precip  (ix, jx, kx))
      allocate (Output_uw%frozen_precip  (ix, jx, kx))
      allocate (Output_uw%total_precip   (ix, jx))
      allocate (Output_uw%scale          (ix, jx))
      allocate (Output_uw%scale_REV      (ix, jx))

      Output_uw%liquid_precip  = 0.
      Output_uw%frozen_precip  = 0.
      Output_uw%total_precip   = 0.
      Output_uw%scale          = 1.0
      Output_uw%scale_REV      = 1.0

!----------------------------------------------------------------------


end subroutine uw_alloc



!#######################################################################

subroutine finalize_uw_outputs (is, js, Input_mp, Uw_tend, Output_uw,  &
                                                             Output_mp)

!---------------------------------------------------------------------
!    subroutine finalize_uw_outputs finishes processing the uw convection
!    results, updates the needed output variables, and produces the
!    diagnostics related to uw convection.
!---------------------------------------------------------------------

integer,                  intent(in)    :: is, js
type(mp_input_type),      intent(inout) :: Input_mp
type(conv_tendency_type), intent(inout) :: Uw_tend
type(conv_output_type),   intent(inout) :: Output_uw
type(mp_output_type),     intent(inout) :: Output_mp

!---------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Uw_tend    conv_tendency_type variable containing tendency
!               output from uw convection
!    Output_uw  conv_output_type variable containing output
!               fields from uw convection
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!-----------------------------------------------------------------------

      logical  :: used
      integer  :: n
      integer  :: nn

!---------------------------------------------------------------------
!   used          logical used to indicate data has been received by
!                 diag_manager_mod
!   n             do loop index
!   nn            counter
!---------------------------------------------------------------------

!---------------------------------------------------------------------
!    call update_inputs to update the components of Input_mp that have
!    been modified by uw convection. 
!---------------------------------------------------------------------
      call update_inputs (Uw_tend, Input_mp)

!---------------------------------------------------------------------
!    call uw_diagnostics to output desired diagnostics related to the
!    uw convection scheme.
!---------------------------------------------------------------------
      call uw_diagnostics (is, js, Input_mp, Uw_tend, Output_uw) 

!-----------------------------------------------------------------------
!    if the warsaw order of calculation (inconsistent) is to be 
!    retained, save the changes to temperature and to the tracers in
!    the variables xxx_tentative, so that they may be applied at a
!    later time. 
!-----------------------------------------------------------------------
      if (reproduce_AM4) then
        Input_mp%tin_tentative = Uw_tend%ttnd*dt 

!------------------------------------------------------------------------
!    save the current tracer tendencies obtained from uw transport.
!------------------------------------------------------------------------
        if (do_limit_uw) then
          nn = 1
          do n=1, num_prog_tracers
            if (tracers_in_uw(n)) then
              Output_mp%rdt_tentative(:,:,:,n) = Uw_tend%qtr(:,:,:,nn)
              nn = nn + 1
            else
              Output_mp%rdt_tentative(:,:,:,n) = 0.
            endif
          end do
        else

!------------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    obtained from uw transport.
!------------------------------------------------------------------------
          nn = 1
          do n=1, num_prog_tracers
            if (tracers_in_uw(n)) then
              Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                                   Uw_tend%qtr(:,:,:,nn)
              nn = nn + 1
            endif
          end do
        endif

!-----------------------------------------------------------------------
!    if warsaw results are to be corrected, the Input_mp%tin
!    and Output_mp%rdt fields are updated with the uw tendencies at this
!    point.
!-----------------------------------------------------------------------
      else
        Input_mp%tin = Input_mp%tin + Uw_tend%ttnd*dt

!------------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    obtained from uw transport.
!------------------------------------------------------------------------
        nn = 1
        do n=1, num_prog_tracers
          if (tracers_in_uw(n)) then
            Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                                   Uw_tend%qtr(:,:,:,nn)
            nn = nn + 1
          endif
        end do
      endif

!---------------------------------------------------------------------


end subroutine finalize_uw_outputs



!#######################################################################

subroutine update_inputs (Uw_tend, Input_mp)

!---------------------------------------------------------------------
!    subroutine update_inputs updates the fields contained in Input_mp
!    that have been modified by the uw convection calculation.
!---------------------------------------------------------------------

type(conv_tendency_type), intent(in)    :: Uw_tend
type(mp_input_type),      intent(inout) :: Input_mp

!----------------------------------------------------------------------
!    Uw_tend    conv_tendency_type variable containing tendency
!               output from uw convection
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!--------------------------------------------------------------------

!-------------------------------------------------------------------------
!    update Input_mp fields with changes from uw_conv.
!-------------------------------------------------------------------------
      Input_mp%qin = Input_mp%qin + Uw_tend%qtnd*dt
      Input_mp%uin = Input_mp%uin + Uw_tend%utnd*dt
      Input_mp%vin = Input_mp%vin + Uw_tend%vtnd*dt
      Input_mp%tracer(:,:,:,nql) = Input_mp%tracer(:,:,:,nql) +    &
                                                       Uw_tend%qltnd*dt
      Input_mp%tracer(:,:,:,nqi) = Input_mp%tracer(:,:,:,nqi) +     &
                                                       Uw_tend%qitnd*dt
      Input_mp%tracer(:,:,:,nqa) = Input_mp%tracer(:,:,:,nqa) +    &
                                                       Uw_tend%qatnd*dt
      if (do_liq_num) then
        Input_mp%tracer(:,:,:,nqn) = Input_mp%tracer(:,:,:,nqn) +   &
                                                       Uw_tend%qntnd*dt
      endif
      if (do_ice_num) then
        Input_mp%tracer(:,:,:,nqni) = Input_mp%tracer(:,:,:,nqni) +   &
                                                       Uw_tend%qnitnd*dt
      endif

!------------------------------------------------------------------


end subroutine update_inputs



!#########################################################################

subroutine uw_diagnostics (is, js, Input_mp, Uw_tend, Output_uw) 

!--------------------------------------------------------------------
!    subroutine uw_diagnostics outputs uw-related diagnostics. 
!--------------------------------------------------------------------

integer,                   intent(in) :: is, js
type(mp_input_type),       intent(in) :: Input_mp
type(conv_tendency_type),  intent(in) :: Uw_tend
type(conv_output_type),    intent(in) :: Output_uw

!-------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Uw_tend    conv_tendency_type variable containing tendency
!               output from uw convection
!    Output_uw  conv_output_type variable containing output
!               fields from uw convection
!-------------------------------------------------------------------

      real, dimension(size(Input_mp%tin,1),   &
                                        size(Input_mp%tin,2)) :: temp_2d
      logical, dimension(size(Input_mp%tin,1),     &
                                        size(Input_mp%tin,2)) :: ltemp
      logical :: used

!----------------------------------------------------------------------
!   temp_2d       temporary real array
!   ltemp         temporary logical array
!   used          logical used to indicate data has been received by
!                 diag_manager_mod
!----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    output the scaling factor.
!-----------------------------------------------------------------------
      used = send_data (id_scale_uw, Output_uw%scale, Time, is, js )

!-----------------------------------------------------------------------
!    output total precip and snow from the uw convection scheme.
!-----------------------------------------------------------------------
      used = send_data (id_uw_precip, Uw_tend%rain + Uw_tend%snow,   &
                                                           Time, is, js)
      used = send_data (id_uw_snow, Uw_tend%snow, Time, is, js)

!-----------------------------------------------------------------------
!    prognostic variable tendencies from uw convection.
!-----------------------------------------------------------------------
      used = send_data (id_tdt_uw, Uw_tend%ttnd, Time, is, js, 1)
      used = send_data (id_qdt_uw, Uw_tend%qtnd, Time, is, js, 1)
      used = send_data (id_qadt_uw, Uw_tend%qatnd, Time, is, js, 1)
      used = send_data (id_qldt_uw, Uw_tend%qltnd, Time, is, js, 1)
      used = send_data (id_qidt_uw, Uw_tend%qitnd, Time, is, js, 1)
      if (do_liq_num) then
        used = send_data (id_qndt_uw, Uw_tend%qntnd, Time, is, js, 1)
      endif
      if (do_ice_num) then
        used = send_data (id_qnidt_uw, Uw_tend%qnitnd, Time, is, js, 1)
      end if

!-------------------------------------------------------------------
!    enthalpy and water column tendencies from uw.
!-------------------------------------------------------------------
      if (id_enth_uw_col > 0) then
        temp_2d = -HLV*Uw_tend%rain -HLS*Uw_tend%snow
        call column_diag (id_enth_uw_col, is, js, Time, Uw_tend%ttnd,  &
                          CP_AIR, Uw_tend%qltnd, -HLV, Uw_tend%qitnd,   &
                                             -HLS, Input_mp%pmass, temp_2d)
      endif

      if (id_wat_uw_col > 0) then
        temp_2d = Uw_tend%rain + Uw_tend%snow
        call column_diag(id_wat_uw_col, is, js, Time, Uw_tend%qtnd, 1.0,  &
                          Uw_tend%qltnd, 1.0, Uw_tend%qitnd, 1.0, &
                                                  Input_mp%pmass, temp_2d)
      endif
        
!----------------------------------------------------------------------
!    uw convection scheme frequency diagnostics.
!----------------------------------------------------------------------
      if (id_uw_freq > 0) then
        ltemp = Uw_tend%rain > 0. .or. Uw_tend%snow > 0.0
        where (ltemp) 
          temp_2d = 1.
        elsewhere
          temp_2d = 0.
        end where
        used = send_data (id_uw_freq, temp_2d, Time, is, js)
      endif

!----------------------------------------------------------------------


end subroutine uw_diagnostics 



!#######################################################################

subroutine uw_dealloc (Uw_tend, Output_uw)

!-----------------------------------------------------------------------
!    subroutine uw_dealloc deallocates the components of the derived type
!    variables Uw_tend and Output_uw.
!-----------------------------------------------------------------------

type(conv_tendency_type), intent(inout) :: Uw_tend
type(conv_output_type),   intent(inout) :: Output_uw

!------------------------------------------------------------------------
!    Uw_tend      conv_tendency_type variable containing tendency
!                 output from uw convection
!    Output_uw    conv_output_type variable containing output
!                 fields from uw convection
!------------------------------------------------------------------------
!---------------------------------------------------------------------
!    deallocate the Uw_tend components.
!---------------------------------------------------------------------
      deallocate (Uw_tend%delta_q)
      deallocate (Uw_tend%rain)
      deallocate (Uw_tend%snow)
      deallocate (Uw_tend%ttnd)
      deallocate (Uw_tend%qtnd)
      deallocate (Uw_tend%utnd)
      deallocate (Uw_tend%vtnd)
      deallocate (Uw_tend%qltnd)
      deallocate (Uw_tend%qitnd)
      deallocate (Uw_tend%qatnd)
      deallocate (Uw_tend%qntnd)
      deallocate (Uw_tend%qnitnd)
      deallocate (Uw_tend%qtr    )

!---------------------------------------------------------------------
!    deallocate the Output_uw components.
!---------------------------------------------------------------------
      deallocate (Output_uw%liquid_precip  )
      deallocate (Output_uw%frozen_precip  )
      deallocate (Output_uw%total_precip   )
      deallocate (Output_uw%scale          )
      deallocate (Output_uw%scale_REV   )

!---------------------------------------------------------------------


end subroutine uw_dealloc 



!#######################################################################



!*******************************************************************
!
!                     RAS-RELATED SUBROUTINES
!
!*******************************************************************

!#######################################################################

subroutine ras_driver (is, js, Input_mp, Output_mp, Tend_mp,  &
                                         Conv_results, C2ls_mp, Aerosol)

!---------------------------------------------------------------------
!    subroutine ras_driver executes ras_mod by allocating needed 
!    derived-type components, calling its module driver, processing its 
!    output into the form needed by other parameterizations active in the 
!    atmospheric model, calling wet deposition to transport any tracers, 
!    outputting any desired ras diagnostics, and then deallocating those 
!    derived-type components which were allocated. 
!-----------------------------------------------------------------------

integer,                     intent(in)           :: is, js
type (mp_input_type),        intent(inout)        :: Input_mp
type (mp_output_type),       intent(inout)        :: Output_mp
type (mp_tendency_type),     intent(inout)        :: Tend_mp
type(conv_results_type),     intent(inout)        :: Conv_results
type(mp_conv2ls_type),       intent(inout)        :: C2ls_mp
type(aerosol_type),          intent(in), optional :: Aerosol

!----------------------------------------------------------------------
!    is,js      starting i and j indices for window
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!    Conv_results
!               conv_results_type variable containing variables 
!               used in multiple convective parameterizations and for
!               diagnostic output
!    C2ls_mp    derived type used to transfer data from convection_driver
!               to lscloud_driver via moist_processes.
!    Aerosol    derived type containing model aerosol fields to be input
!               to model convective schemes
!----------------------------------------------------------------------

      real, dimension(size(Input_mp%tin,1),    & 
                      size(Input_mp%tin,2), size(Input_mp%tin,3)) :: &
                                                              f_snow_berg
      logical, dimension(size(Input_mp%tin,1),    & 
                                          size(Input_mp%tin,2)) :: ltemp

      real, dimension(size(Input_mp%tin,1),    & 
                                     size(Input_mp%tin,2)) :: temp_2d

      real, dimension(size(Output_mp%rdt,1), size(Output_mp%rdt,2),  &
                         size(Output_mp%rdt,3),num_ras_tracers) :: trcr

      type(conv_tendency_type) :: Ras_tend
      integer                  :: nn, n
      integer                  :: nt
      integer                  :: ix, jx, kx
      logical                  :: used

!----------------------------------------------------------------------
!    f_snow_berg  fraction of snow/ice produced having IFN (ice-forming
!                 nuclei)
!    ltemp        temporary logical array
!    temp_2d      temporary real array
!    trcr         set of tracers transported by ras convection
!    Ras_tend     conv_tendency_type variable containing tendency
!                 output from ras convection
!    n            do-loop index
!    nn           counter
!    nt           number of prognostic tracers
!    ix, jx, kx   physics window dimensions
!    used         logical used to indicate data has been received by
!                 diag_manager_mod
!-------------------------------------------------------------------

!---------------------------------------------------------------------
!    turn on ras clock.
!--------------------------------------------------------------------
      call mpp_clock_begin (ras_clock)

!---------------------------------------------------------------------
!    define physics window dimensions.
!---------------------------------------------------------------------
      ix = size(Input_mp%t,1) 
      jx = size(Input_mp%t,2) 
      kx = size(Input_mp%t,3) 

!--------------------------------------------------------------------
!    allocate and initialize the needed components of the 
!    conv_tendency_type for ras convection.
!--------------------------------------------------------------------
      allocate (Ras_tend%rain   (ix, jx))  ! rain_ras
      allocate (Ras_tend%snow   (ix, jx))  ! snow_ras
      allocate (Ras_tend%rain3d (ix, jx, kx+1))
      allocate (Ras_tend%snow3d (ix, jx, kx+1))
      allocate (Ras_tend%ttnd   (ix, jx, kx))
      allocate (Ras_tend%qtnd   (ix, jx, kx))
      allocate (Ras_tend%utnd   (ix, jx, kx))
      allocate (Ras_tend%vtnd   (ix, jx, kx))
      allocate (Ras_tend%qltnd  (ix, jx, kx))
      allocate (Ras_tend%qitnd  (ix, jx, kx))
      allocate (Ras_tend%qatnd  (ix, jx, kx))
      allocate (Ras_tend%qntnd  (ix, jx, kx))
      allocate (Ras_tend%qnitnd (ix, jx, kx))
      allocate (Ras_tend%qtr    (ix, jx, kx, num_ras_tracers))

      Ras_tend%rain = 0.
      Ras_tend%snow = 0.
      Ras_tend%rain3d = 0.
      Ras_tend%snow3d = 0.
      Ras_tend%ttnd = 0.
      Ras_tend%qtnd = 0.
      Ras_tend%utnd = 0.
      Ras_tend%vtnd = 0.
      Ras_tend%qltnd = 0.
      Ras_tend%qitnd = 0.
      Ras_tend%qatnd = 0.
      Ras_tend%qntnd = 0.
      Ras_tend%qnitnd = 0.
      Ras_tend%qtr     = 0.

!----------------------------------------------------------------------
!    if any tracers are to be transported by ras convection, check each
!    active tracer to find those to be transported and fill the 
!    ras_tracers array with these fields.
!---------------------------------------------------------------------
      nn = 1
      do n=1, num_prog_tracers
        if (tracers_in_ras(n)) then
          trcr(:,:,:,nn) = Input_mp%tracer(:,:,:,n)
          nn = nn + 1
        endif
      end do

!----------------------------------------------------------------------
!    call subroutine ras to obtain the temperature, specific humidity,
!    velocity, precipitation and tracer tendencies and mass flux 
!    associated with the relaxed arakawa-schubert parameterization.
!----------------------------------------------------------------------
      if (doing_prog_clouds .and. (.not.do_liq_num)) then
        call ras (is, js, Time, Input_mp%tin, Input_mp%qin,   &
                  Input_mp%uin, Input_mp%vin, Input_mp%pfull,   &
                  Input_mp%phalf, Input_mp%zhalf, Input_mp%coldT, &
                  dt, Ras_tend%ttnd, Ras_tend%qtnd, Ras_tend%utnd,  &
                  Ras_tend%vtnd, Ras_tend%rain3d, Ras_tend%snow3d,  &
                  Ras_tend%rain, Ras_tend%snow, trcr, Ras_tend%qtr,  &
                  mc0=Conv_results%ras_mflux,   &
                  det0=Conv_results%ras_det_mflux,     &
                  ql0=Input_mp%tracer(:,:,:,nql),   &
                  qi0=Input_mp%tracer(:,:,:,nqi),    &
                  qa0=Input_mp%tracer(:,:,:,nqa),   &
                  dl0=Ras_tend%qltnd,     &
                  di0=Ras_tend%qitnd,    &
                  da0=Ras_tend%qatnd)       

      elseif (doing_prog_clouds .and. do_liq_num) then
        call ras (is, js, Time, Input_mp%tin, Input_mp%qin,    &
                  Input_mp%uin, Input_mp%vin, Input_mp%pfull,   &
                  Input_mp%phalf, Input_mp%zhalf, Input_mp%coldT, &
                  dt, Ras_tend%ttnd, Ras_tend%qtnd, Ras_tend%utnd,   &
                  Ras_tend%vtnd, Ras_tend%rain3d, Ras_tend%snow3d,   &
                  Ras_tend%rain, Ras_tend%snow, trcr, Ras_tend%qtr,   &
                  mc0=Conv_results%ras_mflux,     &
                  det0=Conv_results%ras_det_mflux,    &
                  ql0=Input_mp%tracer(:,:,:,nql),   &
                  qi0=Input_mp%tracer(:,:,:,nqi),    &
                  qa0=Input_mp%tracer(:,:,:,nqa),    &
                  dl0=Ras_tend%qltnd,     &
                  di0=Ras_tend%qitnd,     &
                  da0=Ras_tend%qatnd,  &      
                  qn0=Input_mp%tracer(:,:,:,nqn),    &
                  dn0=Ras_tend%qntnd,     &
                  do_strat=doing_prog_clouds, Aerosol=Aerosol)
      else
        call ras (is, js, Time, Input_mp%tin, Input_mp%qin,   &
                  Input_mp%uin, Input_mp%vin, Input_mp%pfull,   &
                  Input_mp%phalf, Input_mp%zhalf, Input_mp%coldT, &
                  dt, Ras_tend%ttnd, Ras_tend%qtnd, Ras_tend%utnd,  &
                  Ras_tend%vtnd, Ras_tend%rain3d, Ras_tend%snow3d,   &
                  Ras_tend%rain, Ras_tend%snow, trcr, Ras_tend%qtr,   &
                  mc0=Conv_results%ras_mflux,    &
                  det0=Conv_results%ras_det_mflux)
      endif

!---------------------------------------------------------------------
!    update the current tracer tendencies with the contributions 
!    just obtained from ras transport.
!    NOTE : the prognostic cloud tracers are updated within ras.        
!---------------------------------------------------------------------
      nn = 1
      do n=1, num_prog_tracers
        if (tracers_in_ras(n)) then
          Output_mp%rdt(:,:,:,n) = Output_mp%rdt(:,:,:,n) +   &
                                               Ras_tend%qtr (:,:,:,nn)
          nn = nn + 1
        endif
      end do

!------------------------------------------------------------------------
!    if prognostic ice number is activated, call detr_ice_num to update
!    its value after ice detrainment is calculated (proportional to ice 
!    mass).
!------------------------------------------------------------------------
      if (doing_prog_clouds) then
        if (do_ice_num .AND. detrain_ice_num) THEN
          CALL detr_ice_num (Input_mp%tin, Ras_tend%qitnd(:,:,:),   &
                                               Ras_tend%qnitnd(:,:,:)) 
        end if
      endif

!-----------------------------------------------------------------------
!    call update_outputs to update tendency fields in Output_mp% and
!    Ras_tend% that are needed later.
!-----------------------------------------------------------------------
      call update_outputs (Ras_tend, Output_mp, Tend_mp)

!------------------------------------------------------------------------
!    initialize fields needed for call to wet deposition routine.
!------------------------------------------------------------------------
      f_snow_berg = 0.
      C2ls_mp%wet_data = 0.0
      C2ls_mp%cloud_frac = 0.1
      C2ls_mp%cloud_wet = 1.e-3
      Tend_mp%qtnd_wet(:,:,:) = Tend_mp%qtnd(:,:,:)
      if (doing_prog_clouds) then
        Tend_mp%qtnd_wet(:,:,:) = Tend_mp%qtnd_wet(:,:,:) +   &
                                  Tend_mp%q_tnd(:,:,:,nql) +    &
                                  Tend_mp%q_tnd(:,:,:,nqi)
      end if

!---------------------------------------------------------------------
!    for each tracer for which wet deposition has been requested, call
!    subroutine wet_deposition to calculate the tracer tendency due to 
!    wet deposition (wetdeptnd) caused by the convectively generated 
!    precipitation (rain, snow). 
!---------------------------------------------------------------------
      nt = size(Output_mp%rdt,4)
      do n=1, nt
        if (.not. cloud_tracer(n)) then
          Tend_mp%wetdeptnd(:,:,:) = 0.0
          call wet_deposition   &
              (n, Input_mp%t, Input_mp%pfull, Input_mp%phalf,   &
               Input_mp%zfull, Input_mp%zhalf,   &
               Ras_tend%rain, Ras_tend%snow,  &
               Tend_mp%qtnd_wet, C2ls_mp%cloud_wet, C2ls_mp%cloud_frac,  &
               f_snow_berg, Ras_tend%rain3d, Ras_tend%snow3d,  &
               Input_mp%tracer(:,:,:,n), Tend_mp%wetdeptnd, Time,   &
               'convect', is, js, dt )

!-----------------------------------------------------------------------
!    add this tendency to the tracer tendency due to all physics (rdt). 
!    save it also in an array which will be combined with any wet 
!    deposition resulting from large-scale precip producing the total wet 
!    deposition for the tracer (wet_data).
!---------------------------------------------------------------------
          Output_mp%rdt (:,:,:,n) = Output_mp%rdt(:,:,:,n) -   &
                                                 Tend_mp%wetdeptnd(:,:,:)
          C2ls_mp%wet_data(:,:,:,n) = Tend_mp%wetdeptnd(:,:,:)
        endif
      end do

!------------------------------------------------------------------------
!    output ras-related convective diagnostics.
!---------------------------------------------------------------------
!    precipitation from ras:
      used = send_data (id_ras_precip, Ras_tend%rain + Ras_tend%snow,  &
                                                            Time, is, js)
!    rain from ras:
      used = send_data ( id_conv_rain3d, Ras_tend%rain3d, Time, is, js, 1 )
!    snow from ras:
      used = send_data ( id_conv_snow3d, Ras_tend%snow3d, Time, is, js, 1 )
!    ras frequency:
      if (id_ras_freq > 0) then
        ltemp = Ras_tend%rain > 0. .or. Ras_tend%snow > 0.0
        where (ltemp) 
          temp_2d = 1.
        elsewhere
          temp_2d = 0.
        end where
        used = send_data (id_ras_freq, temp_2d,Time, is, js)
      endif

!-----------------------------------------------------------------------
!    deallocate the components of the Ras_tend variable.
!-----------------------------------------------------------------------
      deallocate (Ras_tend%rain)
      deallocate (Ras_tend%snow)
      deallocate (Ras_tend%rain3d)
      deallocate (Ras_tend%snow3d)
      deallocate (Ras_tend%ttnd)
      deallocate (Ras_tend%qtnd)
      deallocate (Ras_tend%utnd)
      deallocate (Ras_tend%vtnd)
      deallocate (Ras_tend%qltnd)
      deallocate (Ras_tend%qitnd)
      deallocate (Ras_tend%qatnd)
      deallocate (Ras_tend%qntnd)
      deallocate (Ras_tend%qnitnd)
      deallocate (Ras_tend%qtr    )

!-----------------------------------------------------------------------
!    turn off the ras clock.
!-----------------------------------------------------------------------
      call mpp_clock_end (ras_clock)

!-----------------------------------------------------------------------


end subroutine ras_driver



!*******************************************************************
!
!      PRIVATE SUBROUTINES USED BY MULTIPLE CONVECTION SCHEMES
!
!*******************************************************************


!#######################################################################

subroutine update_outputs (Conv_tend, Output_mp, Tend_mp)
                      
!-----------------------------------------------------------------------
!    subroutine update_outputs updates the physics tendency, convection 
!    tendency and moist_processes tendency arrays with the contributions 
!    from the current convection parameterization.
!-----------------------------------------------------------------------

type(conv_tendency_type),  intent(in)    :: Conv_tend
type(mp_output_type),      intent(inout) :: Output_mp
type(mp_tendency_type),    intent(inout) :: Tend_mp

!----------------------------------------------------------------------
!    Conv_tend  conv_tendency_type variable containing tendency
!               output from the current convective parameterization
!    Output_mp  derived type used to transfer output fields between
!               convection_driver and moist_processes
!    Tend_mp    derived type used to transfer calculated tendency data
!               between convection_driver and moist_processes
!----------------------------------------------------------------------

!-----------------------------------------------------------------------
!    update the physics tendency, convection tendency and moist_processes
!    tendency arrays with the contributions from the current convection
!    scheme. dependent on scheme, some of these fields may not be relevant
!    and so are not allocated.
!-------------------------------------------------------------------
      if (allocated ( Conv_tend%ttnd)) then 
        Output_mp%tdt = Output_mp%tdt + Conv_tend%ttnd
        Tend_mp%ttnd_conv = Tend_mp%ttnd_conv + Conv_tend%ttnd
        Tend_mp%ttnd = Tend_mp%ttnd + Conv_tend%ttnd
      endif
      if (allocated ( Conv_tend%qtnd)) then 
        Output_mp%rdt(:,:,:,1) = Output_mp%rdt(:,:,:,1) + Conv_tend%qtnd
        Tend_mp%qtnd_conv = Tend_mp%qtnd_conv + Conv_tend%qtnd
        Tend_mp%qtnd = Tend_mp%qtnd + Conv_tend%qtnd
      endif
      if (allocated ( Conv_tend%utnd)) &
        Output_mp%udt = Output_mp%udt + Conv_tend%utnd
      if (allocated ( Conv_tend%vtnd)) &
        Output_mp%vdt = Output_mp%vdt + Conv_tend%vtnd
      if (allocated ( Conv_tend%rain)) &
        Output_mp%lprec = Output_mp%lprec + Conv_tend%rain
      if (allocated ( Conv_tend%snow)) &
        Output_mp%fprec = Output_mp%fprec + Conv_tend%snow

!-----------------------------------------------------------------------
!    define the total precipitation rate (precip) for all schemes.
!    the different definition here is done to preserve order of
!    operations with the warsaw code release and avoid answer change
!    with this revised code.
!-----------------------------------------------------------------------
      if (ldonner_then_uw) then
        Output_mp%precip = Output_mp%precip + Conv_tend%rain +   &
                                                        Conv_tend%snow
      else
        Output_mp%precip = Output_mp%lprec + Output_mp%fprec     
      endif

!-----------------------------------------------------------------------
!    define tendencies for prognostic clloud fields, if that option is
!    active.
!-----------------------------------------------------------------------
      if (doing_prog_clouds) then
        if (allocated ( Conv_tend%qltnd)) &
          Output_mp%rdt(:,:,:,nql) = Output_mp%rdt(:,:,:,nql) +   &
                                                       Conv_tend%qltnd
        if (allocated ( Conv_tend%qitnd)) &
          Output_mp%rdt(:,:,:,nqi) = Output_mp%rdt(:,:,:,nqi) +  &
                                                       Conv_tend%qitnd
        if (allocated ( Conv_tend%qatnd)) &
          Output_mp%rdt(:,:,:,nqa) = Output_mp%rdt(:,:,:,nqa) +     &
                                                       Conv_tend%qatnd
        if (allocated ( Conv_tend%qntnd)) then 
          if (do_liq_num) Output_mp%rdt(:,:,:,nqn) =    &
                              Output_mp%rdt(:,:,:,nqn) + Conv_tend%qntnd
        endif
        if (allocated ( Conv_tend%qnitnd))  then 
          if (do_ice_num) Output_mp%rdt(:,:,:,nqni) =    &
                            Output_mp%rdt(:,:,:,nqni) + Conv_tend%qnitnd
        endif
      endif

!-----------------------------------------------------------------------


end subroutine update_outputs



!########################################################################

subroutine define_and_apply_scale (Input_mp, Conv_tend, Output_conv,&
                                          donner_scheme, uw_scheme, qtr)

!-----------------------------------------------------------------------
!    subroutine define_and_apply_scale defines a factor to modify
!    predicted tendencies so that negative values of water and water
!    phases are not produced by the convection scheme, and values lower
!    than a specified minimum are not retained.
!    it is called by both the donner and uw parameterizations, but in
!    slightly different ways in earlier code versions (warsaw and earlier).
!    those differences are preserved here to avoid changing answers; 
!    ultimately it is desirable to treat the functionality of this
!    subroutine in the same way whenever it is employed.
!-----------------------------------------------------------------------

type(mp_input_type),       intent(in)     :: Input_mp
type(conv_tendency_type),  intent(inout)  :: Conv_tend
type(conv_output_type),    intent(inout)  :: Output_conv
logical,                   intent(in)     :: donner_scheme, uw_scheme
real, dimension(:,:,:,:),  intent(inout)  :: qtr

!-----------------------------------------------------------------------
!    Input_mp   derived type used to transfer needed input data between
!               moist_processes and convection_driver
!    Conv_tend  conv_tendency_type variable containing tendency
!               output from the current convective parameterization
!    Output_conv 
!               conv_output_type variable containing output
!               fields from the convection parameterization being processed
!    donner_scheme
!               logical indicating if the routine is to be handled as the
!               original donner convection code did
!    uw_scheme  logical indicating if the routine is to be handled as the
!               original uw convection code did
!    qtr        set of tracers being transported by the current convective
!               parameterization
!------------------------------------------------------------------------

      real, dimension(size(Input_mp%qin,1), size(Input_mp%qin,2),   &
                                           size(Input_mp%qin,3)) :: temp
      real          :: posdef, delta_posdef
      integer       :: ix, jx, kx                          
      integer       :: i, j, k, n 
      integer       :: nn                          

!------------------------------------------------------------------------
!    temp            temporary array
!    posdef          value of field that is to be kept non-negative before
!                    convection was calculated
!    delta_posdef    change in non-negative field due to convective 
!                    parameterization
!    ix, jx, kx      physics window dimensions
!    i, j, k, n      do loop indices
!    nn              counter
!------------------------------------------------------------------------

!-----------------------------------------------------------------------
!    define array dimensions.
!-----------------------------------------------------------------------
      ix = size(Input_mp%qin,1)
      jx = size(Input_mp%qin,2)
      kx = size(Input_mp%qin,3)

      if (uw_scheme) then
!------------------------------------------------------------------------
!    prevent the formation of negative liquid and ice, following the 
!    method employed in the warsaw code for the uw parameterization.
!------------------------------------------------------------------------
        temp = Input_mp%tracer(:,:,:,nql)/dt + Conv_tend%qltnd
        where (temp(:,:,:) .lt. 0.)
          Conv_tend%ttnd  = Conv_tend%ttnd  - temp*HLV/CP_AIR
          Conv_tend%qtnd  = Conv_tend%qtnd  + temp
          Conv_tend%qltnd = Conv_tend%qltnd - temp
        end where

        temp = Input_mp%tracer(:,:,:,nqi)/dt + Conv_tend%qitnd
        where (temp .lt. 0.)
          Conv_tend%ttnd  = Conv_tend%ttnd  - temp*HLS/CP_AIR
          Conv_tend%qtnd  = Conv_tend%qtnd  + temp
          Conv_tend%qitnd = Conv_tend%qitnd - temp
        end where

!------------------------------------------------------------------------
!    if the amount of condensate formed by convective activity is below a 
!    prescribed minimum, set the change in cloud area on this step to be
!    0.0.
!------------------------------------------------------------------------
        where (abs(Conv_tend%qltnd + Conv_tend%qitnd)*dt .lt. qmin)
          Conv_tend%qatnd = 0.0
        end where

      else if (donner_scheme) then
!------------------------------------------------------------------------
!    prevent the formation of negative liquid and ice, following the 
!    method employed in the warsaw code for the donner parameterization.
!    in this case if more evaporation is requested than there is condensate
!    available, the evaporation is limited to the amount present, and the
!    necessary changes to the temperature and specific humidity are made
!    to reflect this modification in cloud evaporation.
!------------------------------------------------------------------------

!--------------------------------------------------------------------------
!  in this case donner requests more cloud evaporation than there is
!  cloudwater present. Therefore we limit the conversion to be simply the 
!  evaporation of the cloud water initially present to prevent the creation
!  of negative water. 
!  the condensation tendencies  are of opposite sign in the qv and ql
!  equations and so
!        delta_qvc = -delta_qlc
!  Thus we want to replace the delta_qlc and delta_qvc with ql_in in both 
!  the qv and ql equations.
!     Adjusted tendencies:
!        delta q = delta_qvc - delta_qvc + ql_in 
! (a)            = delta_qvc + (delta_qlc + ql_in)  
!        delta ql = delta_qlc - delta_qlc - ql_in 
! (b)             = delta_qlc - ( delta_qlc + ql_in)
!                 = -ql_in

!   Here (a) and (b) are the expressions used below and so the new values 
!   of qv and ql:
!      new qv = qv_in + delta_q  = qv_in + delta_qvc + delta_qlc + ql_in 
!                            = qv_in + (delta_qvc + delta_qlc) + ql_in
!                            = qv_in + ql_in
!      new ql = ql_in + delta_ql = ql_in - ql_in  = 0.0
!   so that conservation of water substance is preserved.
!----------------------------------------------------------------------- 
        where ((Input_mp%tracer(:,:,:,nql) + Output_conv%delta_ql) .lt. 0.)
          Output_conv%delta_temp  = Output_conv%delta_temp -   &
                                    (Input_mp%tracer(:,:,:,nql) +    &
                                      Output_conv%delta_ql)*HLV/CP_AIR
          Output_conv%delta_q     = Output_conv%delta_q +   &
                                        (Input_mp%tracer(:,:,:,nql) +   &
                                                    Output_conv%delta_ql)
          Output_conv%delta_ql    = Output_conv%delta_ql -   &
                                       (Input_mp%tracer(:,:,:,nql) +    &
                                                    Output_conv%delta_ql)
        end where

!------------------------------------------------------------------------
!    same treatment for ice as was done for liquid immediately above.
!------------------------------------------------------------------------
        where ((Input_mp%tracer(:,:,:,nqi) + Output_conv%delta_qi) .lt. 0.)
          Output_conv%delta_temp  = Output_conv%delta_temp -   &
                         (Input_mp%tracer(:,:,:,nqi) +    &
                                        Output_conv%delta_qi)*HLS/CP_AIR
          Output_conv%delta_q     = Output_conv%delta_q +    &
                                    (Input_mp%tracer(:,:,:,nqi) +   &
                                                    Output_conv%delta_qi)
          Output_conv%delta_qi    = Output_conv%delta_qi -    &
                                     (Input_mp%tracer(:,:,:,nqi)+    &
                                                  Output_conv%delta_qi)
        end where

!-------------------------------------------------------------------------
!    if the amount of condensate formed by convective activity is below a 
!    prescribed minimum, set the change in cloud area on this step to be
!    0.0.
!------------------------------------------------------------------------
        where (abs(Output_conv%delta_ql + Output_conv%delta_qi) .lt. qmin )
          Output_conv%delta_qa = 0.0
        end where
      endif

!-----------------------------------------------------------------------
!    compute a scaling factor for each grid point.  when this factor is
!    multiplied by the predicted tendencies, they will be reduced in
!    mgnitude to prevent the creation of negative water.
!-----------------------------------------------------------------------
      do k=1,kx
        do j=1,jx
          do i=1,ix

!-----------------------------------------------------------------------
!    the uw scheme used the total water substance as the positive definite
!    quantity that was to be preserved.
!-----------------------------------------------------------------------
            if (uw_scheme) then
              posdef = Input_mp%qin(i,j,k) + Input_mp%tracer(i,j,k,nql) + &
                                                Input_mp%tracer(i,j,k,nqi)
              delta_posdef  = ( Conv_tend%qtnd(i,j,k) +    &
                                      Conv_tend%qltnd(i,j,k) +   &
                                              Conv_tend%qitnd(i,j,k) )*dt

!-----------------------------------------------------------------------
!    the donner scheme used the specific humidity as the positive 
!    definite quantity that was to be preserved.
!-----------------------------------------------------------------------
            else if (donner_scheme) then
              posdef = Input_mp%qin(i,j,k) 
              delta_posdef  = (Output_conv%delta_q(i,j,k) )
            endif

!-------------------------------------------------------------------------
!    if the positive definite quantity is being reduced on this step and
!    the value of that quantity after the timestep will be lower than
!    the minimum value specified, then the tendencies must be reduced to
!    preserve realizability. the percentage of predicted tendency that
!    will not cause negative values is given by the negative of the ratio 
!    of the initial field value to the predicted change (temp). 
!    temp will be a nonnegative number since posdef is positive.
!------------------------------------------------------------------------
            if (delta_posdef .lt.0 .and.    &
                            posdef + delta_posdef .lt. qmin   ) then
              temp(i,j,k) = max( 0.0, -(posdef - qmin)/delta_posdef )
            else
              temp(i,j,k) = 1.0
            endif
          end do
        end do
      end do

!-----------------------------------------------------------------------
!    the scaling factor for each column is defined as the minimum value 
!    of that ratio that is found within that column.  that value is applied
!    at each point in the column. this assures both that fields will not 
!    become negative, and that column conservation of enthalpy and water 
!    substance will not be affected by this adjustment.
!-----------------------------------------------------------------------
      Output_conv%scale = minval( temp, dim=3 )

!-----------------------------------------------------------------------
!    now apply the scaling factor to the water tracer, momentum, 
!    temperature, precipitation  and transported tracer tendencies 
!    returned from the convection scheme. NOte again that uw and donner
!    were originally treated differently, and that different treatment
!    is retained.
!    NOTE THAT THE TRANSPORTED TRACERS WERE NOT SCALED IN THE WARSAW
!    AND EARLIER CODE VERSIONS. THIS INCLUSION HERE MAY CHANGE ANSWERS.
!-----------------------------------------------------------------------
      if (uw_scheme) then
        do k=1,kx
          Conv_tend%utnd(:,:,k)  = Output_conv%scale*Conv_tend%utnd(:,:,k)
          Conv_tend%vtnd(:,:,k)  = Output_conv%scale*Conv_tend%vtnd(:,:,k)
          Conv_tend%ttnd(:,:,k)  = Output_conv%scale*Conv_tend%ttnd(:,:,k)
          Conv_tend%qtnd(:,:,k)  = Output_conv%scale*Conv_tend%qtnd(:,:,k)
          Conv_tend%qltnd(:,:,k) = Output_conv%scale*Conv_tend%qltnd(:,:,k)
          Conv_tend%qitnd(:,:,k) = Output_conv%scale*Conv_tend%qitnd(:,:,k)
          Conv_tend%qatnd(:,:,k) = Output_conv%scale*Conv_tend%qatnd(:,:,k)
        end do

        if (do_liq_num) then
          do k=1,kx
            Conv_tend%qntnd(:,:,k) = Output_conv%scale*  &
                                                  Conv_tend%qntnd(:,:,k)
          end do
        end if

        if (do_ice_num) then
          do k=1,kx
            Conv_tend%qnitnd(:,:,k) = Output_conv%scale*   &
                                                 Conv_tend%qnitnd(:,:,k)
          end do
        end if

        Conv_tend%rain(:,:) = Output_conv%scale*Conv_tend%rain(:,:)
        Conv_tend%snow(:,:) = Output_conv%scale*Conv_tend%snow(:,:)

!----------------------------------------------------------------------
!    apply scaling in the donner convection manner.
!----------------------------------------------------------------------
      else if (donner_scheme) then
        do j=1,jx
          do i=1,ix
            if (Output_conv%scale(i,j) /= 1.0) then

!-------------------------------------------------------------------------
!    scale the convective tendencies of temperature, water tracers and
!    tracers transported by the donner convection scheme. note donner 
!    convection does not affect momentum, droplet number or ice crystal
!    number tendencies.
!RSH 7/28/18: SHOULD PROBABLY AFFECT QN AND QNI, ALSO PRECIP WHICH NOT
!    MODIFIED HERE. CHECK THESE OUT AFTER COMPLETE BENCHMARK TESTING.
!    MAY USE REPRODUCE_AM4 TO MAINTAIN PREVIOUS ANSWERS.
!-------------------------------------------------------------------------
              do k=1,kx
                Output_conv%delta_temp(i,j,k)  =    &
                            Output_conv%scale(i,j)*   &
                                            Output_conv%delta_temp(i,j,k)
                Output_conv%delta_q(i,j,k)  =  &
                            Output_conv%scale(i,j)* &
                                              Output_conv%delta_q (i,j,k)
                Output_conv%delta_qa(i,j,k) =    &
                            Output_conv%scale(i,j)*  &
                                              Output_conv%delta_qa(i,j,k)
                Output_conv%delta_ql(i,j,k) =    &
                            Output_conv%scale(i,j)* &
                                              Output_conv%delta_ql(i,j,k)
                Output_conv%delta_qi(i,j,k) =   &
                             Output_conv%scale(i,j)* &
                                              Output_conv%delta_qi(i,j,k)
              end do
              nn = 1
              do n=1, num_prog_tracers
                if (tracers_in_donner(n)) then
                  do k=1,kx
                    qtr(i,j,k,nn) = Output_conv%scale(i,j)*qtr(i,j,k,nn)
                  end do
                  nn = nn + 1
                endif
              end do
            endif
          end do
        end do
      endif

!-------------------------------------------------------------------------


end subroutine define_and_apply_scale



!#####################################################################



                  end module convection_driver_mod
