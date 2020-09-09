!**********************************************************************************************************************************
! WLaCava (WGL), Matt Lackner (MAL),  Meghan Glade (MEG), and Semyung Park (SP)
! Tuned Mass Damper Module
!**********************************************************************************************************************************
MODULE StrucCtrl

   USE StrucCtrl_Types
   USE NWTC_Library

   IMPLICIT NONE

   PRIVATE


   TYPE(ProgDesc), PARAMETER            :: StC_Ver = ProgDesc( 'StrucCtrl', '', '' )




      ! ..... Public Subroutines ...................................................................................................

   PUBLIC :: StC_Init                           ! Initialization routine
   PUBLIC :: StC_End                            ! Ending routine (includes clean up)

   PUBLIC :: StC_UpdateStates                   ! Loose coupling routine for solving for constraint states, integrating
                                                    !   continuous states, and updating discrete states
   PUBLIC :: StC_CalcOutput                     ! Routine for computing outputs

  ! PUBLIC :: StC_CalcConstrStateResidual        ! Tight coupling routine for returning the constraint state residual
   PUBLIC :: StC_CalcContStateDeriv             ! Tight coupling routine for computing derivatives of continuous states

   !PUBLIC :: StC_UpdateDiscState                ! Tight coupling routine for updating discrete states

   !PUBLIC :: StC_JacobianPInput                 ! Routine to compute the Jacobians of the output (Y), continuous- (X), discrete-
   !                                                 !   (Xd), and constraint-state (Z) equations all with respect to the inputs (u)
   !PUBLIC :: StC_JacobianPContState             ! Routine to compute the Jacobians of the output (Y), continuous- (X), discrete-
   !                                                 !   (Xd), and constraint-state (Z) equations all with respect to the continuous
   !                                                 !   states (x)
   !PUBLIC :: StC_JacobianPDiscState             ! Routine to compute the Jacobians of the output (Y), continuous- (X), discrete-
   !                                                 !   (Xd), and constraint-state (Z) equations all with respect to the discrete
   !                                                 !   states (xd)
   !PUBLIC :: StC_JacobianPConstrState           ! Routine to compute the Jacobians of the output (Y), continuous- (X), discrete-
                                                    !   (Xd), and constraint-state (Z) equations all with respect to the constraint
                                                    !   states (z)


   INTEGER(IntKi), PRIVATE, PARAMETER :: ControlMode_NONE      = 0          !< The (StC-universal) control code for not using a particular type of control

   INTEGER(IntKi), PRIVATE, PARAMETER :: DOFMode_Indept        = 1          !< independent DOFs
   INTEGER(IntKi), PRIVATE, PARAMETER :: DOFMode_Omni          = 2          !< omni-directional
   INTEGER(IntKi), PRIVATE, PARAMETER :: DOFMode_TLCD          = 3          !< tuned liquid column dampers !MEG & SP
   INTEGER(IntKi), PRIVATE, PARAMETER :: DOFMode_Prescribed    = 4          !< prescribed force series

   INTEGER(IntKi), PRIVATE, PARAMETER :: CMODE_Semi            = 1          !< semi-active control
   INTEGER(IntKi), PRIVATE, PARAMETER :: CMODE_Active          = 2          !< active control

   INTEGER(IntKi), PRIVATE, PARAMETER :: SA_CMODE_GH_vel       = 1          !< 1: velocity-based ground hook control;
   INTEGER(IntKi), PRIVATE, PARAMETER :: SA_CMODE_GH_invVel    = 2          !< 2: Inverse velocity-based ground hook control
   INTEGER(IntKi), PRIVATE, PARAMETER :: SA_CMODE_GH_disp      = 3          !< 3: displacement-based ground hook control
   INTEGER(IntKi), PRIVATE, PARAMETER :: SA_CMODE_Ph_FF        = 4          !< 4: Phase difference Algorithm with Friction Force
   INTEGER(IntKi), PRIVATE, PARAMETER :: SA_CMODE_Ph_DF        = 5          !< 5: Phase difference Algorithm with Damping Force


CONTAINS
!----------------------------------------------------------------------------------------------------------------------------------
!> This routine is called at the start of the simulation to perform initialization steps.
!! The parameters are set here and not changed during the simulation.
!! The initial states and initial guess for the input are defined.
SUBROUTINE StC_Init( InitInp, u, p, x, xd, z, OtherState, y, m, Interval, InitOut, ErrStat, ErrMsg )
!..................................................................................................................................

      TYPE(StC_InitInputType),       INTENT(INOUT)  :: InitInp     !< Input data for initialization routine.
      TYPE(StC_InputType),           INTENT(  OUT)  :: u           !< An initial guess for the input; input mesh must be defined
      TYPE(StC_ParameterType),       INTENT(  OUT)  :: p           !< Parameters
      TYPE(StC_ContinuousStateType), INTENT(  OUT)  :: x           !< Initial continuous states
      TYPE(StC_DiscreteStateType),   INTENT(  OUT)  :: xd          !< Initial discrete states
      TYPE(StC_ConstraintStateType), INTENT(  OUT)  :: z           !< Initial guess of the constraint states
      TYPE(StC_OtherStateType),      INTENT(  OUT)  :: OtherState  !< Initial other states
      TYPE(StC_OutputType),          INTENT(INOUT)  :: y           !< Initial system outputs (outputs are not calculated;
                                                                   !!   only the output mesh is initialized)
      TYPE(StC_MiscVarType),         INTENT(  OUT)  :: m           !< Misc (optimization) variables
      REAL(DbKi),                    INTENT(INOUT)  :: Interval    !< Coupling interval in seconds: the rate that
                                                                   !!   (1) StC_UpdateStates() is called in loose coupling &
                                                                   !!   (2) StC_UpdateDiscState() is called in tight coupling.
                                                                   !!   Input is the suggested time from the glue code;
                                                                   !!   Output is the actual coupling interval that will be used
                                                                   !!   by the glue code.
      TYPE(StC_InitOutputType),      INTENT(  OUT)  :: InitOut     !< Output for initialization routine
      INTEGER(IntKi),                INTENT(  OUT)  :: ErrStat     !< Error status of the operation
      CHARACTER(*),                  INTENT(  OUT)  :: ErrMsg      !< Error message if ErrStat /= ErrID_None


         ! Local variables
      INTEGER(IntKi)                                :: NumOuts
      TYPE(StC_InputFile)                           :: InputFileData ! Data stored in the module's input file
      INTEGER(IntKi)                                :: i_pt          ! Generic counter for mesh point
      REAL(ReKi), allocatable, dimension(:,:)       :: PositionP
      REAL(ReKi), allocatable, dimension(:,:)       :: PositionGlobal
      REAL(R8Ki), allocatable, dimension(:,:,:)     :: OrientationP

      INTEGER(IntKi)                                :: UnEcho        ! Unit number for the echo file
      INTEGER(IntKi)                                :: ErrStat2      ! local error status
      CHARACTER(ErrMsgLen)                          :: ErrMsg2       ! local error message

      CHARACTER(*), PARAMETER                       :: RoutineName = 'StC_Init'

         ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = ''
      NumOuts = 0

   InitOut%dummyInitOut = 0.0_SiKi  ! initialize this so compiler doesn't warn about un-set intent(out) variables

     ! Initialize the NWTC Subroutine Library
   CALL NWTC_Init( EchoLibVer=.FALSE. )

      ! Display the module information
   CALL DispNVD( StC_Ver )

    !............................................................................................
    ! Read the input file and validate the data
    !............................................................................................

   CALL StC_ReadInput( InitInp%InputFile, InputFileData, Interval, TRIM(InitInp%RootName), ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF (ErrStat >= AbortErrLev) RETURN

   CALL StC_ValidatePrimaryData( InputFileData, InitInp, ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
       IF (ErrStat >= AbortErrLev) RETURN

      !............................................................................................
      ! Define parameters here:
      !............................................................................................
   CALL StC_SetParameters( InputFileData, InitInp, p, Interval, ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF (ErrStat >= AbortErrLev) RETURN

      !............................................................................................
      ! Define initial system states here:
      !............................................................................................

   xd%DummyDiscState = 0
   z%DummyConstrState = 0

   ! Initialize other states here:
   OtherState%DummyOtherState = 0

   call Init_Misc( p, m, ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF (ErrStat >= AbortErrLev) RETURN


   ! Allocate continuous states (x)
   call AllocAry(x%StC_x, 4, p%NumMeshPts, 'x%StC_x',  ErrStat2,ErrMsg2)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF (ErrStat >= AbortErrLev) RETURN

   ! Define initial guess for the system states here:
   do i_pt=1,p%NumMeshPts
      x%StC_x(1,i_pt) = p%X_DSP
      x%StC_x(2,i_pt) = 0
      x%StC_x(3,i_pt) = p%Y_DSP
      x%StC_x(4,i_pt) = 0
   enddo


   ! set positions and orientations for tuned mass dampers's
   call AllocAry(PositionP,       3, p%NumMeshPts, 'PositionP',      ErrStat2,ErrMsg2); CALL CheckError( ErrStat2, ErrMsg2 )
   call AllocAry(PositionGlobal,  3, p%NumMeshPts, 'PositionGlobal', ErrStat2,ErrMsg2); CALL CheckError( ErrStat2, ErrMsg2 )
   call AllocAry(OrientationP, 3, 3, p%NumMeshPts, 'OrientationP',   ErrStat2,ErrMsg2); CALL CheckError( ErrStat2, ErrMsg2 )
      IF (ErrStat >= AbortErrLev) RETURN

   ! Set the initial positions and orietantions for each point
   do i_pt = 1,p%NumMeshPts
      PositionP(:,i_pt)      = (/ InputFileData%StC_P_X, InputFileData%StC_P_Y, InputFileData%StC_P_Z /)
      OrientationP(:,:,i_pt) = InitInp%InitOrientation(:,:,i_pt)
      PositionGlobal(:,i_pt) = InitInp%InitPosition(:,i_pt) + real( matmul(PositionP(:,i_pt),OrientationP(:,:,i_pt)), ReKi)
   enddo

    ! Define system output initializations (set up mesh) here:
    ! Create the input and output meshes associated with lumped loads

   ALLOCATE (u%Mesh(p%NumMeshPts), STAT=ErrStat2)
   IF (ErrStat2/=0) THEN
      CALL SetErrStat(ErrID_Fatal,"Error allocating u%Mesh.",ErrStat,ErrMsg,RoutineName)
      CALL Cleanup()
      RETURN
   END IF
   ALLOCATE (y%Mesh(p%NumMeshPts), STAT=ErrStat2)
   IF (ErrStat2/=0) THEN
      CALL SetErrStat(ErrID_Fatal,"Error allocating y%Mesh.",ErrStat,ErrMsg,RoutineName)
      CALL Cleanup()
      RETURN
   END IF

   ! Create Mesh(i_pt)
   DO i_pt = 1,p%NumMeshPts

      CALL MeshCreate( BlankMesh        = u%Mesh(i_pt)      &
                     ,IOS               = COMPONENT_INPUT   &
                     ,Nnodes            = 1                 &
                     ,ErrStat           = ErrStat2          &
                     ,ErrMess           = ErrMsg2           &
                     ,TranslationDisp   = .TRUE.            &
                     ,Orientation       = .TRUE.            &
                     ,TranslationVel    = .TRUE.            &
                     ,RotationVel       = .TRUE.            &
                     ,TranslationAcc    = .TRUE.            &
                     ,RotationAcc       = .TRUE.)
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
         IF ( ErrStat >= AbortErrLev ) THEN
            CALL Cleanup()
            RETURN
         END IF


         ! Create the node on the mesh
         ! make position node at point P (rest position of tuned mass dampers, somewhere above the yaw bearing)
      CALL MeshPositionNode ( u%Mesh(i_pt),1, PositionGlobal(:,i_pt), ErrStat2, ErrMsg2, OrientationP(:,:,i_pt) )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)

         ! Create the mesh element
      CALL MeshConstructElement (  u%Mesh(i_pt)        &
                                  , ELEMENT_POINT      &
                                  , ErrStat2           &
                                  , ErrMsg2            &
                                  , 1                  )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
      CALL MeshCommit ( u%Mesh(i_pt)        &
                      , ErrStat2            &
                      , ErrMsg2             )
         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
         IF ( ErrStat >= AbortErrLev ) THEN
            CALL Cleanup()
            RETURN
         END IF

      CALL MeshCopy ( SrcMesh      = u%Mesh(i_pt)           &
                     ,DestMesh     = y%Mesh(i_pt)           &
                     ,CtrlCode     = MESH_SIBLING           &
                     ,IOS          = COMPONENT_OUTPUT       &
                     ,ErrStat      = ErrStat2               &
                     ,ErrMess      = ErrMsg2                &
                     ,Force        = .TRUE.                 &
                     ,Moment       = .TRUE.                 )

         CALL SetErrStat( ErrStat2, ErrMsg2, ErrStat, ErrMsg, RoutineName)
         IF ( ErrStat >= AbortErrLev ) THEN
            CALL Cleanup()
            RETURN
         END IF

      u%Mesh(i_pt)%RemapFlag  = .TRUE.
      y%Mesh(i_pt)%RemapFlag  = .TRUE.
   enddo


   !bjj: removed for now; output handled in ServoDyn
    !IF (NumOuts > 0) THEN
    !   ALLOCATE( y%WriteOutput(NumOuts), STAT = ErrStat )
    !   IF ( ErrStat/= 0 ) THEN
    !      CALL SetErrStat(ErrID_Fatal,'Error allocating output array.',ErrStat,ErrMsg,'StC_Init')
    !      CALL Cleanup()
    !      RETURN
    !   END IF
    !   y%WriteOutput = 0
    !
    !   ! Define initialization-routine output here:
    !   ALLOCATE( InitOut%WriteOutputHdr(NumOuts), InitOut%WriteOutputUnt(NumOuts), STAT = ErrStat )
    !   IF ( ErrStat/= 0 ) THEN
    !      CALL SetErrStat(ErrID_Fatal,'Error allocating output header and units arrays.',ErrStat,ErrMsg,'StC_Init')
    !      CALL Cleanup()
    !      RETURN
    !   END IF
    !
    !   DO i=1,NumOuts
    !        InitOut%WriteOutputHdr(i) = "Heading"//trim(num2lstr(i))
    !        InitOut%WriteOutputUnt(i) = "(-)"
    !   END DO
    !
    !END IF

    !bjj: need to initialize headers/units

    ! If you want to choose your own rate instead of using what the glue code suggests, tell the glue code the rate at which
    ! this module must be called here:
    !Interval = p%DT

   call cleanup()
!................................
CONTAINS
   subroutine Init_Misc( p, m, ErrStat, ErrMsg )
      type(StC_ParameterType),intent(in   )  :: p        !< Parameters
      type(StC_MiscVarType),  intent(inout)  :: m        !< Misc (optimization) variables
      integer(IntKi),         intent(  out) :: ErrStat   ! The error identifier (ErrStat)
      character(ErrMsgLen),   intent(  out) :: ErrMsg    ! The error message (ErrMsg)

      !  Accelerations, velocities, and resultant forces -- used in all tuned mass calcs (so we don't reallocate all the time)
      !  Note: these variables had been allocated multiple places before and sometimes passed between routines. So
      !        they have been moved into MiscVars so that we don so we don't reallocate all the time
      call AllocAry(m%a_G    , 3, p%NumMeshPts,'a_G'     , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;
      call AllocAry(m%rddot_P, 3, p%NumMeshPts,'rddot_P' , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;
      call AllocAry(m%omega_P, 3, p%NumMeshPts,'omega_P' , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;
      call AllocAry(m%alpha_P, 3, p%NumMeshPts,'alpha_P' , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;
      call AllocAry(m%Acc    , 3, p%NumMeshPts,'Acc'     , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;    ! Summed accelerations
      !  Note: the following two were added to misc so that we have the option of outputting the forces and moments
      !        from each tuned mass system at some later point
      call AllocAry(m%F_P    , 3, p%NumMeshPts,'F_P'     , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;
      call AllocAry(m%M_P    , 3, p%NumMeshPts,'M_P'     , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;

      !  External and stop forces
      !  Note: these variables had been allocated multiple places before and sometimes passed between routines. So
      !        they have been moved into MiscVars so that we don so we don't reallocate all the time.
      call AllocAry(m%F_stop , 2, p%NumMeshPts, 'F_stop' , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%F_stop  = 0.0_ReKi
      call AllocAry(m%F_ext  , 2, p%NumMeshPts, 'F_ext'  , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%F_ext   = 0.0_ReKi
      call AllocAry(m%F_fr   , 2, p%NumMeshPts, 'F_fr'   , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%F_fr    = 0.0_ReKi
      call AllocAry(m%C_ctrl , 2, p%NumMeshPts, 'C_ctrl' , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%C_ctrl  = 0.0_ReKi
      call AllocAry(m%C_Brake, 2, p%NumMeshPts, 'C_Brake', ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%C_Brake = 0.0_ReKi
      call AllocAry(m%F_table, 2, p%NumMeshPts, 'F_table', ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%F_table = 0.0_ReKi
      call AllocAry(m%F_k    , 2, p%NumMeshPts, 'F_k'    , ErrStat, ErrMsg);  if (ErrStat >= AbortErrLev) return;  m%F_k     = 0.0_ReKi

      ! indexing
      m%PrescribedInterpIdx = 0_IntKi ! index tracker for PrescribedForce option

   end subroutine Init_Misc
   !.........................................
   SUBROUTINE CheckError(ErrID,Msg)
   ! This subroutine sets the error message and level and cleans up if the error is >= AbortErrLev
   !...............................................................................................................................

         ! Passed arguments
      INTEGER(IntKi), INTENT(IN) :: ErrID       ! The error identifier (ErrStat)
      CHARACTER(*),   INTENT(IN) :: Msg         ! The error message (ErrMsg)


      !............................................................................................................................
      ! Set error status/message;
      !............................................................................................................................

      IF ( ErrID /= ErrID_None ) THEN

         IF (ErrStat /= ErrID_None) ErrMsg = TRIM(ErrMsg)//NewLine
         ErrMsg = TRIM(ErrMsg)//'StC_Init:'//TRIM(Msg)
         ErrStat = MAX(ErrStat, ErrID)

         !.........................................................................................................................
         ! Clean up if we're going to return on error: close files, deallocate local arrays
         !.........................................................................................................................
         IF ( ErrStat >= AbortErrLev ) THEN
            call cleanup()
         END IF

      END IF


   END SUBROUTINE CheckError
   !.........................................
   SUBROUTINE cleanup()

   IF ( UnEcho > 0 ) CLOSE( UnEcho )
   if (allocated(PositionP     ))   deallocate(PositionP     )
   if (allocated(PositionGlobal))   deallocate(PositionGlobal)
   if (allocated(OrientationP  ))   deallocate(OrientationP  )
   CALL StC_DestroyInputFile( InputFileData, ErrStat2, ErrMsg2)      ! Ignore warnings here.

   END SUBROUTINE cleanup
!.........................................
END SUBROUTINE StC_Init
!----------------------------------------------------------------------------------------------------------------------------------
!> This routine is called at the end of the simulation.
SUBROUTINE StC_End( u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg )
!..................................................................................................................................

      TYPE(StC_InputType),           INTENT(INOUT)  :: u           !< System inputs
      TYPE(StC_ParameterType),       INTENT(INOUT)  :: p           !< Parameters
      TYPE(StC_ContinuousStateType), INTENT(INOUT)  :: x           !< Continuous states
      TYPE(StC_DiscreteStateType),   INTENT(INOUT)  :: xd          !< Discrete states
      TYPE(StC_ConstraintStateType), INTENT(INOUT)  :: z           !< Constraint states
      TYPE(StC_OtherStateType),      INTENT(INOUT)  :: OtherState  !< Other states
      TYPE(StC_OutputType),          INTENT(INOUT)  :: y           !< System outputs
      TYPE(StC_MiscVarType),         INTENT(INOUT)  :: m           !< Misc (optimization) variables
      INTEGER(IntKi),                INTENT(  OUT)  :: ErrStat     !< Error status of the operation
      CHARACTER(*),                  INTENT(  OUT)  :: ErrMsg      !< Error message if ErrStat /= ErrID_None


         ! Initialize ErrStat

      ErrStat = ErrID_None
      ErrMsg  = ""


         ! Place any last minute operations or calculations here:



         ! Write the StrucCtrl-level output file data if the user requested module-level output
         ! and the current time has advanced since the last stored time step.



         ! Close files here:


         ! Destroy the input data:

      CALL StC_DestroyInput( u, ErrStat, ErrMsg )


         ! Destroy the parameter data:

      CALL StC_DestroyParam( p, ErrStat, ErrMsg )


         ! Destroy the state data:

      CALL StC_DestroyContState(   x,           ErrStat, ErrMsg )
      CALL StC_DestroyDiscState(   xd,          ErrStat, ErrMsg )
      CALL StC_DestroyConstrState( z,           ErrStat, ErrMsg )
      CALL StC_DestroyOtherState(  OtherState,  ErrStat, ErrMsg )

      CALL StC_DestroyMisc(  m,  ErrStat, ErrMsg )

         ! Destroy the output data:

      CALL StC_DestroyOutput( y, ErrStat, ErrMsg )

END SUBROUTINE StC_End
!----------------------------------------------------------------------------------------------------------------------------------
!> Loose coupling routine for solving constraint states, integrating continuous states, and updating discrete states.
!! Continuous, constraint, and discrete states are updated to values at t + Interval.
SUBROUTINE StC_UpdateStates( t, n, Inputs, InputTimes, p, x, xd, z, OtherState, m, ErrStat, ErrMsg )
!..................................................................................................................................

      REAL(DbKi),                         INTENT(IN   )  :: t               !< Current simulation time in seconds
      INTEGER(IntKi),                     INTENT(IN   )  :: n               !< Current step of the simulation: t = n*Interval
      TYPE(StC_InputType),                INTENT(INOUT)  :: Inputs(:)       !< Inputs at InputTimes
      REAL(DbKi),                         INTENT(IN   )  :: InputTimes(:)   !< Times in seconds associated with Inputs
      TYPE(StC_ParameterType),            INTENT(IN   )  :: p               !< Parameters
      TYPE(StC_ContinuousStateType),      INTENT(INOUT)  :: x               !< Input: Continuous states at t;
                                                                            !!   Output: Continuous states at t + Interval
      TYPE(StC_DiscreteStateType),        INTENT(INOUT)  :: xd              !< Input: Discrete states at t;
                                                                            !!   Output: Discrete states at t + Interval
      TYPE(StC_ConstraintStateType),      INTENT(INOUT)  :: z               !< Input: Constraint states at t;
                                                                            !!   Output: Constraint states at t + Interval
      TYPE(StC_OtherStateType),           INTENT(INOUT)  :: OtherState      !< Input: Other states at t;
                                                                            !!   Output: Other states at t + Interval
      TYPE(StC_MiscVarType),              INTENT(INOUT)  :: m               !< Misc (optimization) variables
      INTEGER(IntKi),                     INTENT(  OUT)  :: ErrStat         !< Error status of the operation
      CHARACTER(*),                       INTENT(  OUT)  :: ErrMsg          !< Error message if ErrStat /= ErrID_None

         ! Local variables
      !INTEGER                                            :: I               ! Generic loop counter
      !TYPE(StC_ContinuousStateType)                      :: dxdt            ! Continuous state derivatives at t
      !TYPE(StC_DiscreteStateType)                        :: xd_t            ! Discrete states at t (copy)
      !TYPE(StC_ConstraintStateType)                      :: z_Residual      ! Residual of the constraint state functions (Z)
      !TYPE(StC_InputType)                                :: u               ! Instantaneous inputs
      !INTEGER(IntKi)                                     :: ErrStat2        ! Error status of the operation (secondary error)
      !CHARACTER(ErrMsgLen)                               :: ErrMsg2         ! Error message if ErrStat2 /= ErrID_None
      !INTEGER                                            :: nTime           ! number of inputs


      IF ( p%StC_DOF_MODE /= DOFMode_Prescribed ) THEN
         CALL StC_RK4( t, n, Inputs, InputTimes, p, x, xd, z, OtherState, m, ErrStat, ErrMsg )
      ENDIF

END SUBROUTINE StC_UpdateStates
!----------------------------------------------------------------------------------------------------------------------------------
!> This subroutine implements the fourth-order Runge-Kutta Method (RK4) for numerically integrating ordinary differential equations:
!!
!!   Let f(t, x) = xdot denote the time (t) derivative of the continuous states (x).
!!   Define constants k1, k2, k3, and k4 as
!!        k1 = dt * f(t        , x_t        )
!!        k2 = dt * f(t + dt/2 , x_t + k1/2 )
!!        k3 = dt * f(t + dt/2 , x_t + k2/2 ), and
!!        k4 = dt * f(t + dt   , x_t + k3   ).
!!   Then the continuous states at t = t + dt are
!!        x_(t+dt) = x_t + k1/6 + k2/3 + k3/3 + k4/6 + O(dt^5)
!!
!! For details, see:
!! Press, W. H.; Flannery, B. P.; Teukolsky, S. A.; and Vetterling, W. T. "Runge-Kutta Method" and "Adaptive Step Size Control for
!!   Runge-Kutta." Sections 16.1 and 16.2 in Numerical Recipes in FORTRAN: The Art of Scientific Computing, 2nd ed. Cambridge, England:
!!   Cambridge University Press, pp. 704-716, 1992.
SUBROUTINE StC_RK4( t, n, u, utimes, p, x, xd, z, OtherState, m, ErrStat, ErrMsg )
!..................................................................................................................................

      REAL(DbKi),                    INTENT(IN   )  :: t           !< Current simulation time in seconds
      INTEGER(IntKi),                INTENT(IN   )  :: n           !< time step number
      TYPE(StC_InputType),           INTENT(INOUT)  :: u(:)        !< Inputs at t (out only for mesh record-keeping in ExtrapInterp routine)
      REAL(DbKi),                    INTENT(IN   )  :: utimes(:)   !< times of input
      TYPE(StC_ParameterType),       INTENT(IN   )  :: p           !< Parameters
      TYPE(StC_ContinuousStateType), INTENT(INOUT)  :: x           !< Continuous states at t on input at t + dt on output
      TYPE(StC_DiscreteStateType),   INTENT(IN   )  :: xd          !< Discrete states at t
      TYPE(StC_ConstraintStateType), INTENT(IN   )  :: z           !< Constraint states at t (possibly a guess)
      TYPE(StC_OtherStateType),      INTENT(INOUT)  :: OtherState  !< Other states at t
      TYPE(StC_MiscVarType),         INTENT(INOUT)  :: m           !< Misc (optimization) variables
      INTEGER(IntKi),                INTENT(  OUT)  :: ErrStat     !< Error status of the operation
      CHARACTER(*),                  INTENT(  OUT)  :: ErrMsg      !< Error message if ErrStat /= ErrID_None

      ! local variables

      TYPE(StC_ContinuousStateType)                 :: xdot        ! time derivatives of continuous states
      TYPE(StC_ContinuousStateType)                 :: k1          ! RK4 constant; see above
      TYPE(StC_ContinuousStateType)                 :: k2          ! RK4 constant; see above
      TYPE(StC_ContinuousStateType)                 :: k3          ! RK4 constant; see above
      TYPE(StC_ContinuousStateType)                 :: k4          ! RK4 constant; see above

      TYPE(StC_ContinuousStateType)                 :: x_tmp       ! Holds temporary modification to x
      TYPE(StC_InputType)                           :: u_interp    ! interpolated value of inputs
      integer(IntKi)                                :: i_pt        ! Generic counter for mesh point

      INTEGER(IntKi)                                :: ErrStat2    ! local error status
      CHARACTER(ErrMsgLen)                          :: ErrMsg2     ! local error message (ErrMsg)


         ! Initialize ErrStat
      ErrStat = ErrID_None
      ErrMsg  = ""

      CALL StC_CopyContState( x, k1, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
      CALL StC_CopyContState( x, k2, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
      CALL StC_CopyContState( x, k3, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
      CALL StC_CopyContState( x, k4,    MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
      CALL StC_CopyContState( x, x_tmp, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      CALL StC_CopyInput( u(1), u_interp, MESH_NEWCOPY, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      ! interpolate u to find u_interp = u(t)
      CALL StC_Input_ExtrapInterp( u, utimes, u_interp, t, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      ! find xdot at t
      CALL StC_CalcContStateDeriv( t, u_interp, p, x, xd, z, OtherState, m, xdot, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      do i_pt=1,p%NumMeshPts
         k1%StC_x(:,i_pt)     = p%dt * xdot%StC_x(:,i_pt)
         x_tmp%StC_x(:,i_pt)  = x%StC_x(:,i_pt)  + 0.5 * k1%StC_x(:,i_pt)
      enddo


      ! interpolate u to find u_interp = u(t + dt/2)
      CALL StC_Input_ExtrapInterp(u, utimes, u_interp, t+0.5*p%dt, ErrStat2, ErrMsg2)
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      ! find xdot at t + dt/2
      CALL StC_CalcContStateDeriv( t + 0.5*p%dt, u_interp, p, x_tmp, xd, z, OtherState, m, xdot, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      do i_pt=1,p%NumMeshPts
         k2%StC_x(:,i_pt)     = p%dt * xdot%StC_x(:,i_pt)
         x_tmp%StC_x(:,i_pt)  = x%StC_x(:,i_pt)  + 0.5 * k2%StC_x(:,i_pt)
      enddo


      ! find xdot at t + dt/2
      CALL StC_CalcContStateDeriv( t + 0.5*p%dt, u_interp, p, x_tmp, xd, z, OtherState, m, xdot, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      do i_pt=1,p%NumMeshPts
         k3%StC_x(:,i_pt)     = p%dt * xdot%StC_x(:,i_pt)
         x_tmp%StC_x(:,i_pt)  = x%StC_x(:,i_pt)  + k3%StC_x(:,i_pt)
      enddo


      ! interpolate u to find u_interp = u(t + dt)
      CALL StC_Input_ExtrapInterp(u, utimes, u_interp, t + p%dt, ErrStat2, ErrMsg2)
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      ! find xdot at t + dt
      CALL StC_CalcContStateDeriv( t + p%dt, u_interp, p, x_tmp, xd, z, OtherState, m, xdot, ErrStat2, ErrMsg2 )
         CALL CheckError(ErrStat2,ErrMsg2)
         IF ( ErrStat >= AbortErrLev ) RETURN

      do i_pt=1,p%NumMeshPts
         k4%StC_x(:,i_pt) = p%dt * xdot%StC_x(:,i_pt)
         x%StC_x(:,i_pt)   = x%StC_x(:,i_pt)  +  ( k1%StC_x(:,i_pt)  + 2. * k2%StC_x(:,i_pt)  + 2. * k3%StC_x(:,i_pt)  + k4%StC_x(:,i_pt)  ) / 6.
         ! x%StC_dxdt = x%StC_dxdt +  ( k1%StC_dxdt + 2. * k2%StC_dxdt + 2. * k3%StC_dxdt + k4%StC_dxdt ) / 6.
      enddo

         ! clean up local variables:
      CALL ExitThisRoutine(  )

CONTAINS
   !...............................................................................................................................
   SUBROUTINE ExitThisRoutine()
   ! This subroutine destroys all the local variables
   !...............................................................................................................................

         ! local variables
      INTEGER(IntKi)             :: ErrStat3    ! The error identifier (ErrStat)
      CHARACTER(ErrMsgLen)       :: ErrMsg3     ! The error message (ErrMsg)


      CALL StC_DestroyContState( xdot,     ErrStat3, ErrMsg3 )
      CALL StC_DestroyContState( k1,       ErrStat3, ErrMsg3 )
      CALL StC_DestroyContState( k2,       ErrStat3, ErrMsg3 )
      CALL StC_DestroyContState( k3,       ErrStat3, ErrMsg3 )
      CALL StC_DestroyContState( k4,       ErrStat3, ErrMsg3 )
      CALL StC_DestroyContState( x_tmp,    ErrStat3, ErrMsg3 )

      CALL StC_DestroyInput(     u_interp, ErrStat3, ErrMsg3 )

   END SUBROUTINE ExitThisRoutine
   !...............................................................................................................................
   SUBROUTINE CheckError(ErrID,Msg)
   ! This subroutine sets the error message and level and cleans up if the error is >= AbortErrLev
   !...............................................................................................................................

         ! Passed arguments
      INTEGER(IntKi), INTENT(IN) :: ErrID       ! The error identifier (ErrStat)
      CHARACTER(*),   INTENT(IN) :: Msg         ! The error message (ErrMsg)

         ! local variables
      INTEGER(IntKi)             :: ErrStat3    ! The error identifier (ErrStat)
      CHARACTER(ErrMsgLen)       :: ErrMsg3     ! The error message (ErrMsg)

      !............................................................................................................................
      ! Set error status/message;
      !............................................................................................................................

      IF ( ErrID /= ErrID_None ) THEN

         IF (ErrStat /= ErrID_None) ErrMsg = TRIM(ErrMsg)//NewLine
         ErrMsg = TRIM(ErrMsg)//'StC_RK4:'//TRIM(Msg)
         ErrStat = MAX(ErrStat,ErrID)

         !.........................................................................................................................
         ! Clean up if we're going to return on error: close files, deallocate local arrays
         !.........................................................................................................................

         IF ( ErrStat >= AbortErrLev ) CALL ExitThisRoutine( )


      END IF

   END SUBROUTINE CheckError

END SUBROUTINE StC_RK4
!----------------------------------------------------------------------------------------------------------------------------------
!> Routine for computing outputs, used in both loose and tight coupling.
SUBROUTINE StC_CalcOutput( Time, u, p, x, xd, z, OtherState, y, m, ErrStat, ErrMsg )
!..................................................................................................................................

      REAL(DbKi),                    INTENT(IN   )  :: Time        !< Current simulation time in seconds
      TYPE(StC_InputType),           INTENT(IN   )  :: u           !< Inputs at Time
      TYPE(StC_ParameterType),       INTENT(IN   )  :: p           !< Parameters
      TYPE(StC_ContinuousStateType), INTENT(IN   )  :: x           !< Continuous states at Time
      TYPE(StC_DiscreteStateType),   INTENT(IN   )  :: xd          !< Discrete states at Time
      TYPE(StC_ConstraintStateType), INTENT(IN   )  :: z           !< Constraint states at Time
      TYPE(StC_OtherStateType),      INTENT(IN   )  :: OtherState  !< Other states at Time
      TYPE(StC_OutputType),          INTENT(INOUT)  :: y           !< Outputs computed at Time (Input only so that mesh con-
                                                                   !!  nectivity information does not have to be recalculated)
      TYPE(StC_MiscVarType),         INTENT(INOUT)  :: m           !< Misc (optimization) variables
      INTEGER(IntKi),                INTENT(  OUT)  :: ErrStat     !< Error status of the operation
      CHARACTER(*),                  INTENT(  OUT)  :: ErrMsg      !< Error message if ErrStat /= ErrID_None

      !  local variables for force calcualtions in X-DOF, Y-DOF, and XY-DOF
      real(ReKi), dimension(3)   :: F_X_P
      real(ReKi), dimension(3)   :: F_Y_P
      real(ReKi), dimension(3)   :: F_XY_P

      !  NOTE: the following two sets of variables could likely be combined into arrays
      !        that could be more easily used with array functions like MATMUL, cross_product,
      !        dot_product etc.
      ! Fore-aft TLCD reactionary forces !MEG & SP
      Real(ReKi)                 :: F_x_tlcd_WR_N
      Real(ReKi)                 :: F_y_tlcd_WR_N
      Real(ReKi)                 :: F_x_tlcd_WL_N
      Real(ReKi)                 :: F_y_tlcd_WL_N
      Real(ReKi)                 :: F_y_tlcd_WH_N
      Real(ReKi)                 :: F_z_tlcd_WH_N

      ! Side-side orthogonal TLCD reactionary forces !MEG & SP
      Real(ReKi)                 :: F_x_otlcd_WB_N
      Real(ReKi)                 :: F_y_otlcd_WB_N
      Real(ReKi)                 :: F_x_otlcd_WF_N
      Real(ReKi)                 :: F_y_otlcd_WF_N
      Real(ReKi)                 :: F_x_otlcd_WH_N
      Real(ReKi)                 :: F_z_otlcd_WH_N

      TYPE(StC_ContinuousStateType)              :: dxdt    ! first time derivative of continuous states

      integer(IntKi)       :: i,j         !< generic counter
      integer(IntKi)       :: i_pt        ! Generic counter for mesh point

      ! Local error handling
      integer(IntKi)       :: ErrStat2
      character(ErrMsgLen) :: ErrMsg2


      ErrStat = ErrID_None
      ErrMsg  = ""


      ! Compute accelerations and velocities in local coordinates
      do i_pt=1,p%NumMeshPts
         m%a_G(:,i_pt)     = matmul(u%Mesh(i_pt)%Orientation(:,:,1),p%Gravity)
         m%rddot_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%TranslationAcc(:,1))
         m%omega_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%RotationVel(:,1))
         m%alpha_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%RotationAcc(:,1))
      enddo


         ! calculate the derivative, only to get updated values of m, which are used in the equations below
      CALL StC_CalcContStateDeriv( Time, u, p, x, xd, z, OtherState, m, dxdt, ErrStat2, ErrMsg2 ); if (Failed()) return;


      IF (p%StC_DOF_MODE == ControlMode_None .OR. p%StC_DOF_MODE == DOFMode_Indept) THEN

         ! StrucCtrl external forces of dependent degrees:
         do i_pt=1,p%NumMeshPts
            F_X_P(2) = - p%M_X * ( m%a_G(2,i_pt) - m%rddot_P(2,i_pt) - (m%alpha_P(3,i_pt) + m%omega_P(1,i_pt)*m%omega_P(2,i_pt))*x%StC_x(1,i_pt) - 2*m%omega_P(3,i_pt)*x%StC_x(2,i_pt) )
            F_X_P(3) = - p%M_X * ( m%a_G(3,i_pt) - m%rddot_P(3,i_pt) + (m%alpha_P(2,i_pt) - m%omega_P(1,i_pt)*m%omega_P(3,i_pt))*x%StC_x(1,i_pt) + 2*m%omega_P(2,i_pt)*x%StC_x(2,i_pt) )

            F_Y_P(1) = - p%M_Y * ( m%a_G(1,i_pt) - m%rddot_P(1,i_pt) + (m%alpha_P(3,i_pt) - m%omega_P(1,i_pt)*m%omega_P(2,i_pt))*x%StC_x(3,i_pt) + 2*m%omega_P(3,i_pt)*x%StC_x(4,i_pt) )
            F_Y_P(3) = - p%M_Y * ( m%a_G(3,i_pt) - m%rddot_P(3,i_pt) - (m%alpha_P(1,i_pt) + m%omega_P(2,i_pt)*m%omega_P(3,i_pt))*x%StC_x(3,i_pt) - 2*m%omega_P(1,i_pt)*x%StC_x(4,i_pt) )

            ! inertial contributions from mass of tuned mass dampers and acceleration of point
            ! forces and moments in local coordinates
            m%F_P(1,i_pt) =  p%K_X * x%StC_x(1,i_pt) + m%C_ctrl(1,i_pt) * x%StC_x(2,i_pt) + m%C_Brake(1,i_pt) * x%StC_x(2,i_pt) - m%F_stop(1,i_pt) - m%F_ext(1,i_pt) - m%F_fr(1,i_pt) - F_Y_P(1) + m%F_table(1,i_pt)
            m%F_P(2,i_pt) =  p%K_Y * x%StC_x(3,i_pt) + m%C_ctrl(2,i_pt) * x%StC_x(4,i_pt) + m%C_Brake(2,i_pt) * x%StC_x(4,i_pt) - m%F_stop(2,i_pt) - m%F_ext(2,i_pt) - m%F_fr(2,i_pt) - F_X_P(2) + m%F_table(2,i_pt)
            m%F_P(3,i_pt) = - F_X_P(3) - F_Y_P(3)

            m%M_P(1,i_pt) =  - F_Y_P(3)  * x%StC_x(3,i_pt)
            m%M_P(2,i_pt) =    F_X_P(3)  * x%StC_x(1,i_pt)
            m%M_P(3,i_pt) =  - F_Y_P(1)  * x%StC_x(3,i_pt) + F_X_P(2) * x%StC_x(1,i_pt)

            ! forces and moments in global coordinates
            y%Mesh(i_pt)%Force(:,1) =  matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)),m%F_P(1:3,i_pt))
            y%Mesh(i_pt)%Moment(:,1) = matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)),m%M_P(1:3,i_pt))
         enddo

      ELSE IF (p%StC_DOF_MODE == DOFMode_Omni) THEN

         !note: m%F_k is computed earlier in StC_CalcContStateDeriv

         ! StrucCtrl external forces of dependent degrees:
         do i_pt=1,p%NumMeshPts
            F_XY_P(1) = 0
            F_XY_P(2) = 0
            F_XY_P(3) = - p%M_XY * (  m%a_G(3,i_pt) - m%rddot_P(3,i_pt)                                                     &
                                                - (m%alpha_P(1,i_pt) + m%omega_P(2,i_pt)*m%omega_P(3,i_pt))*x%StC_x(3,i_pt)   &
                                                + (m%alpha_P(2,i_pt) - m%omega_P(1,i_pt)*m%omega_P(3,i_pt))*x%StC_x(1,i_pt)   &
                                                - 2*m%omega_P(1,i_pt)*x%StC_x(4,i_pt)                                         &
                                                + 2*m%omega_P(2,i_pt)*x%StC_x(2,i_pt)       )

            ! inertial contributions from mass of tuned mass dampers and acceleration of point
            ! forces and moments in local coordinates
            m%F_P(1,i_pt) =  p%K_X * x%StC_x(1,i_pt) + m%C_ctrl(1,i_pt) * x%StC_x(2,i_pt) + m%C_Brake(1,i_pt) * x%StC_x(2,i_pt) - m%F_stop(1,i_pt) - m%F_ext(1,i_pt) - m%F_fr(1,i_pt) - F_XY_P(1) + m%F_table(1,i_pt)*(m%F_k(1,i_pt))
            m%F_P(2,i_pt) =  p%K_Y * x%StC_x(3,i_pt) + m%C_ctrl(2,i_pt) * x%StC_x(4,i_pt) + m%C_Brake(2,i_pt) * x%StC_x(4,i_pt) - m%F_stop(2,i_pt) - m%F_ext(2,i_pt) - m%F_fr(2,i_pt) - F_XY_P(2) + m%F_table(2,i_pt)*(m%F_k(2,i_pt))
            m%F_P(3,i_pt) = - F_XY_P(3)

            m%M_P(1,i_pt) = - F_XY_P(3) * x%StC_x(3,i_pt)
            m%M_P(2,i_pt) =   F_XY_P(3) * x%StC_x(1,i_pt)
            m%M_P(3,i_pt) = - F_XY_P(1) * x%StC_x(3,i_pt) + F_XY_P(2) * x%StC_x(1,i_pt)

            ! forces and moments in global coordinates
            y%Mesh(i_pt)%Force(:,1) =  matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)),m%F_P(1:3,i_pt))
            y%Mesh(i_pt)%Moment(:,1) = matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)),m%M_P(1:3,i_pt))
         enddo

      ELSE IF (p%StC_DOF_MODE == DOFMode_TLCD) THEN

         do i_pt=1,p%NumMeshPts
            !fore-aft TLCD external forces of dependent degrees
            F_x_tlcd_WR_N = p%rho_X*p%area_X*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt))*(                           &
                                       m%rddot_P(1,i_pt)                                                       &
                                    +2*m%omega_P(2,i_pt)*x%StC_x(2,i_pt)                                       &
                                      +m%alpha_P(2,i_pt)*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt))                   &
                                      -m%omega_P(2,i_pt)*m%omega_P(2,i_pt)*p%B_X*.5                           &
                                      -m%omega_P(3,i_pt)*m%omega_P(3,i_pt)*p%B_X*.5                           &
                                      +m%omega_P(3,i_pt)*m%omega_P(1,i_pt)*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt)) &
                                      -m%a_G(1,i_pt)  )
            F_y_tlcd_WR_N = p%rho_X*p%area_X*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt))*(                           &
                                       m%rddot_P(2,i_pt)                                                       &
                                    -2*m%omega_P(1,i_pt)*x%StC_x(2,i_pt)                                       &
                                      +m%alpha_P(3,i_pt)*p%B_X*.5                                             &
                                      -m%alpha_P(1,i_pt)*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt))                   &
                                      +m%omega_P(3,i_pt)*m%omega_P(2,i_pt)*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt)) &
                                      +m%omega_P(1,i_pt)*m%omega_P(2,i_pt)*p%B_X*.5                           &
                                      -m%a_G(2,i_pt)  )
            F_x_tlcd_WL_N = p%rho_X*p%area_X*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt))*(                           &
                                       m%rddot_P(1,i_pt)                                                       &
                                    -2*m%omega_P(2,i_pt)*x%StC_x(2,i_pt)                                       &
                                      +m%alpha_P(2,i_pt)*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt))                   &
                                      +m%omega_P(2,i_pt)*m%omega_P(2,i_pt)*p%B_X*.5                           &
                                      +m%omega_P(3,i_pt)*m%omega_P(3,i_pt)*p%B_X*.5                           &
                                      +m%omega_P(3,i_pt)*m%omega_P(1,i_pt)*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt)) &
                                      -m%a_G(1,i_pt)  )
            F_y_tlcd_WL_N = p%rho_X*p%area_X*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt))*(                           &
                                       m%rddot_P(2,i_pt)                                                       &
                                    +2*m%omega_P(1,i_pt)*x%StC_x(2,i_pt)                                       &
                                      -m%alpha_P(3,i_pt)*p%B_X*.5                                             &
                                      -m%alpha_P(1,i_pt)*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt))                   &
                                      +m%omega_P(3,i_pt)*m%omega_P(2,i_pt)*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt)) &
                                      -m%omega_P(1,i_pt)*m%omega_P(2,i_pt)*p%B_X*.5                           &
                                      -m%a_G(2,i_pt)  )
            F_y_tlcd_WH_N = p%rho_X*p%area_X/p%area_ratio_X*p%B_X*(                   &
                                       m%rddot_P(2,i_pt)                                  &
                                    +2*m%omega_P(3,i_pt)*p%area_ratio_X*x%StC_x(2,i_pt)  &
                                      -m%a_G(2,i_pt)  )
            F_z_tlcd_WH_N = p%rho_X*p%area_X/p%area_ratio_X*p%B_X*(                   &
                                       m%rddot_P(3,i_pt)                                  &
                                    -2*m%omega_P(2,i_pt)*p%area_ratio_X*x%StC_x(2,i_pt)  &
                                      -m%a_G(3,i_pt)  )

            !side-to-side TLCD external forces of dependent degrees
            F_x_otlcd_WB_N = p%rho_Y*p%area_Y*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))*(                             &
                                         m%rddot_P(1,i_pt)                                                        &
                                      +2*m%omega_P(2,i_pt)*x%StC_x(4,i_pt)                                        &
                                        +m%alpha_P(2,i_pt)*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))                    &
                                        +m%alpha_P(3,i_pt)*p%B_Y/2-m%omega_P(2,i_pt)*m%omega_P(1,i_pt)*p%B_Y/2  &
                                        +m%omega_P(3,i_pt)*m%omega_P(1,i_pt)*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))  &
                                        -m%a_G(1,i_pt)   )
            F_y_otlcd_WB_N = p%rho_Y*p%area_Y*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))*(                             &
                                         m%rddot_P(2,i_pt)                                                        &
                                      -2*m%omega_P(1,i_pt)*x%StC_x(4,i_pt)                                        &
                                        -m%alpha_P(1,i_pt)*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))                    &
                                        +m%omega_P(3,i_pt)*m%omega_P(2,i_pt)*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt))  &
                                        +m%omega_P(3,i_pt)*m%omega_P(3,i_pt)*p%B_Y/2                             &
                                        +m%omega_P(1,i_pt)*m%omega_P(1,i_pt)*p%B_Y/2                             &
                                        -m%a_G(2,i_pt)   )
            F_x_otlcd_WF_N = p%rho_Y*p%area_Y*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))*(                             &
                                         m%rddot_P(1,i_pt)                                                        &
                                      -2*m%omega_P(2,i_pt)*x%StC_x(4,i_pt)                                        &
                                        +m%alpha_P(2,i_pt)*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))                    &
                                        -m%alpha_P(2,i_pt)*p%B_Y/2                                               &
                                        +m%omega_P(2,i_pt)*m%omega_P(1,i_pt)*p%B_Y/2                             &
                                        +m%omega_P(3,i_pt)*m%omega_P(1,i_pt)*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))  &
                                        -m%a_G(1,i_pt)   )
            F_y_otlcd_WF_N = p%rho_Y*p%area_Y*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))*(                             &
                                         m%rddot_P(2,i_pt)                                                        &
                                      +2*m%omega_P(1,i_pt)*x%StC_x(4,i_pt)                                        &
                                        -m%alpha_P(1,i_pt)*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))                    &
                                        +m%omega_P(3,i_pt)*m%omega_P(2,i_pt)*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))  &
                                        -m%omega_P(3,i_pt)*m%omega_P(3,i_pt)*p%B_Y/2                             &
                                        -m%omega_P(1,i_pt)*m%omega_P(1,i_pt)*p%B_Y/2                             &
                                        -m%a_G(2,i_pt)   )
            F_x_otlcd_WH_N = p%rho_Y*p%area_Y/p%area_ratio_Y*p%B_Y*(                     &
                                          m%rddot_P(1,i_pt)                                  &
                                       -2*m%omega_P(3,i_pt)*p%area_ratio_Y*x%StC_x(4,i_pt)  &
                                         -m%a_G(1,i_pt)  )
            F_z_otlcd_WH_N = p%rho_Y*p%area_Y/p%area_ratio_Y*p%B_Y*(                     &
                                          m%rddot_P(3,i_pt)                                  &
                                       +2*m%omega_P(1,i_pt)*p%area_ratio_Y*x%StC_x(4,i_pt)  &
                                         -m%a_G(3,i_pt)  )

            ! forces and moments in local coordinates (from fore-aft and side-to-side TLCDs)
            m%F_P(1,i_pt) = -F_x_tlcd_WR_N - F_x_tlcd_WL_N - p%rho_X*(p%area_X/p%area_ratio_X)*p%B_X*dxdt%StC_x(2,i_pt)*p%area_ratio_X + F_x_otlcd_WB_N + F_x_otlcd_WF_N + F_x_otlcd_WH_N
            m%F_P(2,i_pt) = +F_y_tlcd_WR_N + F_y_tlcd_WL_N - p%rho_Y*(p%area_Y/p%area_ratio_Y)*p%B_Y*dxdt%StC_x(4,i_pt)*p%area_ratio_Y + F_y_tlcd_WH_N  - F_y_otlcd_WB_N - F_y_otlcd_WF_N
            m%F_P(3,i_pt) = -F_z_tlcd_WH_N - F_z_otlcd_WH_N

            m%M_P(1,i_pt) =  F_y_tlcd_WR_N*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt)) + F_y_tlcd_WL_N*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt)) - F_y_otlcd_WB_N*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt)) - F_y_otlcd_WF_N*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))
            m%M_P(2,i_pt) = -F_x_tlcd_WR_N*((p%L_X-p%B_X)/2+x%StC_x(1,i_pt)) - F_x_tlcd_WL_N*((p%L_X-p%B_X)/2-x%StC_x(1,i_pt)) + F_x_otlcd_WB_N*((p%L_Y-p%B_Y)/2+x%StC_x(3,i_pt)) + F_x_otlcd_WF_N*((p%L_Y-p%B_Y)/2-x%StC_x(3,i_pt))
            m%M_P(3,i_pt) =  F_y_tlcd_WR_N*p%B_X*.5 - F_y_tlcd_WL_N*p%B_X*.5 + F_x_otlcd_WB_N*p%B_Y*.5 - F_x_otlcd_WF_N*p%B_Y*.5

            ! forces and moments in global coordinates
            y%Mesh(i_pt)%Force(:,1)  = matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)), m%F_P(1:3,i_pt))
            y%Mesh(i_pt)%Moment(:,1) = matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)), m%M_P(1:3,i_pt))
         enddo
      ENDIF

      IF ( p%StC_DOF_MODE == DOFMode_Prescribed ) THEN
         !  Note that the prescribed force is applied the same to all Mesh pts
         !  that are passed into this instance of the StC
         do i=1,3
            ! Get interpolated force   -- this is not in any particular coordinate system yet
            m%F_P(i,:)    = InterpStp( real(Time,ReKi), p%StC_PrescribedForce(1,:),p%StC_PrescribedForce(i+1,:),m%PrescribedInterpIdx, size(p%StC_PrescribedForce,2))
            ! Get interpolated moment  -- this is not in any particular coordinate system yet
            m%M_P(i,:)    = InterpStp( real(Time,ReKi), p%StC_PrescribedForce(1,:),p%StC_PrescribedForce(i+4,:),m%PrescribedInterpIdx, size(p%StC_PrescribedForce,2))
         enddo
         if (p%PrescribedForcesCoordSys == 0_IntKi) then
            ! Global coords
            do i_pt=1,p%NumMeshPts
               y%Mesh(i_pt)%Force(1:3,1)  =  m%F_P(1:3,i_pt)
               y%Mesh(i_pt)%Moment(1:3,1) =  m%M_P(1:3,i_pt)
            enddo
         elseif (p%PrescribedForcesCoordSys == 1_IntKi) then
            ! local coords
            do i_pt=1,p%NumMeshPts
               y%Mesh(i_pt)%Force(1:3,1)  =  matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)), m%F_P(1:3,i_pt))
               y%Mesh(i_pt)%Moment(1:3,1) =  matmul(transpose(u%Mesh(i_pt)%Orientation(:,:,1)), m%M_P(1:3,i_pt))
            enddo
         endif
      END IF

      call CleanUp()

CONTAINS
   subroutine CleanUp()
      call StC_DestroyContState(dxdt,ErrStat2,ErrMsg2)    !Ignore error status
   end subroutine CleanUp
   logical function Failed()
        call SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, 'StC_CalcOutput')
        Failed =  ErrStat >= AbortErrLev
        if (Failed) call CleanUp()
   end function Failed
END SUBROUTINE StC_CalcOutput

!----------------------------------------------------------------------------------------------------------------------------------
!> Tight coupling routine for computing derivatives of continuous states
SUBROUTINE StC_CalcContStateDeriv( Time, u, p, x, xd, z, OtherState, m, dxdt, ErrStat, ErrMsg )
!..................................................................................................................................

      REAL(DbKi),                    INTENT(IN   )  :: Time        !< Current simulation time in seconds
      TYPE(StC_InputType),           INTENT(IN   )  :: u           !< Inputs at Time
      TYPE(StC_ParameterType),       INTENT(IN   )  :: p           !< Parameters
      TYPE(StC_ContinuousStateType), INTENT(IN   )  :: x           !< Continuous states at Time
      TYPE(StC_DiscreteStateType),   INTENT(IN   )  :: xd          !< Discrete states at Time
      TYPE(StC_ConstraintStateType), INTENT(IN   )  :: z           !< Constraint states at Time
      TYPE(StC_OtherStateType),      INTENT(IN   )  :: OtherState  !< Other states at Time
      TYPE(StC_ContinuousStateType), INTENT(  OUT)  :: dxdt        !< Continuous state derivatives at Time
      TYPE(StC_MiscVarType),         INTENT(INOUT)  :: m           !< Misc (optimization) variables
      INTEGER(IntKi),                INTENT(  OUT)  :: ErrStat     !< Error status of the operation
      CHARACTER(*),                  INTENT(  OUT)  :: ErrMsg      !< Error message if ErrStat /= ErrID_None

      REAL(ReKi), dimension(2)                        :: K          ! tuned mass damper stiffness
      Real(ReKi)                                      :: denom      ! denominator for omni-direction factors
      integer(IntKi)                                  :: i_pt       ! Generic counter for mesh point

      ! Local error handling
      integer(IntKi)       :: ErrStat2
      character(ErrMsgLen) :: ErrMsg2

         ! Initialize ErrStat
      ErrStat = ErrID_None
      ErrMsg  = ""


      call AllocAry(dxdt%StC_x,4, p%NumMeshPts,'dxdt%StC_x',  ErrStat2,ErrMsg2); if (Failed()) return;

         ! compute stop force (m%F_stop)
      IF (p%Use_F_TBL) THEN
         m%F_stop = 0.0_ReKi
      ELSE
         CALL StC_CalcStopForce(x,p,m%F_stop)
      END IF

      ! Compute stiffness
      IF (p%Use_F_TBL) THEN ! use stiffness table
         CALL SpringForceExtrapInterp(x,p,m%F_table,ErrStat2,ErrMsg2);  if (Failed()) return;
         K = 0.0_ReKi
      ELSE ! use preset values
         K(1) = p%K_X
         K(2) = p%K_Y
      END IF


      ! Compute velocities and accelerations in local coordinates
      do i_pt=1,p%NumMeshPts
         m%a_G(:,i_pt)     = matmul(u%Mesh(i_pt)%Orientation(:,:,1),p%Gravity)
         m%rddot_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%TranslationAcc(:,1))
         m%omega_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%RotationVel(:,1))
         m%alpha_P(:,i_pt) = matmul(u%Mesh(i_pt)%Orientation(:,:,1),u%Mesh(i_pt)%RotationAcc(:,1))
      enddo


      ! NOTE: m%F_stop and m%F_table are calculated earlier
      IF (p%StC_DOF_MODE == ControlMode_None .or. p%StC_DOF_MODE == DOFMode_Indept) THEN

         do i_pt=1,p%NumMeshPts
            ! Aggregate acceleration terms
            m%Acc(1,i_pt) = - m%rddot_P(1,i_pt) + m%a_G(1,i_pt) + 1 / p%M_X * ( m%F_ext(1,i_pt) + m%F_stop(1,i_pt) - m%F_table(1,i_pt) )
            m%Acc(2,i_pt) = - m%rddot_P(2,i_pt) + m%a_G(2,i_pt) + 1 / p%M_Y * ( m%F_ext(2,i_pt) + m%F_stop(2,i_pt) - m%F_table(2,i_pt) )
         enddo

      ELSE IF (p%StC_DOF_MODE == DOFMode_Omni) THEN

         do i_pt=1,p%NumMeshPts
            denom = SQRT(x%StC_x(1,i_pt)**2+x%StC_x(3,i_pt)**2)
            IF ( EqualRealNos( denom, 0.0_ReKi) ) THEN
                m%F_k(1,i_pt) = 0.0
                m%F_k(2,i_pt) = 0.0
            ELSE
                  m%F_k(1,i_pt) = x%StC_x(1,i_pt)/denom
                  m%F_k(2,i_pt) = x%StC_x(3,i_pt)/denom
            END IF

            ! Aggregate acceleration terms
            m%Acc(1,i_pt) = - m%rddot_P(1,i_pt) + m%a_G(1,i_pt) + 1 / p%M_XY * ( m%F_ext(1,i_pt) + m%F_stop(1,i_pt) - m%F_table(1,i_pt)*(m%F_k(1,i_pt)) )
            m%Acc(2,i_pt) = - m%rddot_P(2,i_pt) + m%a_G(2,i_pt) + 1 / p%M_XY * ( m%F_ext(2,i_pt) + m%F_stop(2,i_pt) - m%F_table(2,i_pt)*(m%F_k(2,i_pt)) )
         enddo

      ENDIF


      ! Compute the first time derivatives, dxdt%StC_x(1) and dxdt%StC_x(3), of the continuous states,:
      ! Compute elements 1 and 3 of dxdt%StC_x so that we can compute m%C_ctrl,m%C_Brake, and m%F_fr in StC_GroundHookDamp if necessary
      IF (p%StC_DOF_MODE == ControlMode_None) THEN

         dxdt%StC_x = 0.0_ReKi ! Whole array

      ELSE

         IF (p%StC_DOF_MODE == DOFMode_Indept .AND. .NOT. p%StC_X_DOF) THEN
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(1,i_pt) = 0.0_ReKi
            enddo
         ELSE
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(1,i_pt) = x%StC_x(2,i_pt)
            enddo
         END IF

         IF (p%StC_DOF_MODE == DOFMode_Indept .AND. .NOT. p%StC_Y_DOF) THEN
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(3,i_pt) = 0.0_ReKi
            enddo
         ELSE
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(3,i_pt) = x%StC_x(4,i_pt)
            enddo
         END IF

      ENDIF


      ! compute damping for dxdt%StC_x(2) and dxdt%StC_x(4)
      IF (p%StC_CMODE == ControlMode_None) THEN
         m%C_ctrl(1,:) = p%C_X
         m%C_ctrl(2,:) = p%C_Y

         m%C_Brake = 0.0_ReKi
         m%F_fr    = 0.0_ReKi
      ELSE IF (p%StC_CMODE == CMODE_Semi) THEN ! ground hook control
         CALL StC_GroundHookDamp(dxdt,x,u,p,m%C_ctrl,m%C_Brake,m%F_fr)
      END IF


      ! Compute the first time derivatives, dxdt%StC_x(2) and dxdt%StC_x(4), of the continuous states,:
      IF (p%StC_DOF_MODE == DOFMode_Indept) THEN

         IF (p%StC_X_DOF) THEN
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(2,i_pt) =  ( m%omega_P(2,i_pt)**2 + m%omega_P(3,i_pt)**2 - K(1) / p%M_X) * x%StC_x(1,i_pt) &
                                   - ( m%C_ctrl( 1,i_pt)/p%M_X ) * x%StC_x(2,i_pt)                                   &
                                   - ( m%C_Brake(1,i_pt)/p%M_X ) * x%StC_x(2,i_pt)                                   &
                                   + m%Acc(1,i_pt) + m%F_fr(1,i_pt) / p%M_X
            enddo
         ELSE
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(2,i_pt) = 0.0_ReKi
            enddo
         END IF
         IF (p%StC_Y_DOF) THEN
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(4,i_pt) =  ( m%omega_P(1,i_pt)**2 + m%omega_P(3,i_pt)**2 - K(2) / p%M_Y) * x%StC_x(3,i_pt) &
                                   - ( m%C_ctrl( 2,i_pt)/p%M_Y ) * x%StC_x(4,i_pt)                                   &
                                   - ( m%C_Brake(2,i_pt)/p%M_Y ) * x%StC_x(4,i_pt)                                   &
                                   + m%Acc(2,i_pt) + m%F_fr(2,i_pt) / p%M_Y
            enddo
         ELSE
            do i_pt=1,p%NumMeshPts
               dxdt%StC_x(4,i_pt) = 0.0_ReKi
            enddo
         END IF

      ELSE IF (p%StC_DOF_MODE == DOFMode_Omni) THEN
               ! Compute the first time derivatives of the continuous states of Omnidirectional tuned masse damper mode by sm 2015-0904
         do i_pt=1,p%NumMeshPts
            dxdt%StC_x(2,i_pt) =  ( m%omega_P(2,i_pt)**2 + m%omega_P(3,i_pt)**2 - K(1) / p%M_XY) * x%StC_x(1,i_pt)   &
                                - ( m%C_ctrl( 1,i_pt)/p%M_XY ) * x%StC_x(2,i_pt)                                     &
                                - ( m%C_Brake(1,i_pt)/p%M_XY ) * x%StC_x(2,i_pt)                                     &
                                +  m%Acc(1,i_pt) + 1/p%M_XY * ( m%F_fr(1,i_pt) )                                     &
                                - ( m%omega_P(1,i_pt)*m%omega_P(2,i_pt) - m%alpha_P(3,i_pt) ) * x%StC_x(3,i_pt)      &
                               +2 * m%omega_P(3,i_pt) * x%StC_x(4,i_pt)
            dxdt%StC_x(4,i_pt) =  ( m%omega_P(1,i_pt)**2 + m%omega_P(3,i_pt)**2 - K(2) / p%M_XY) * x%StC_x(3,i_pt)   &
                                - ( m%C_ctrl( 2,i_pt)/p%M_XY ) * x%StC_x(4,i_pt)                                     &
                                - ( m%C_Brake(2,i_pt)/p%M_XY ) * x%StC_x(4,i_pt)                                     &
                                +  m%Acc(2,i_pt) + 1/p%M_XY * ( m%F_fr(2,i_pt) )                                     &
                                - ( m%omega_P(1,i_pt)*m%omega_P(2,i_pt) + m%alpha_P(3,i_pt) ) * x%StC_x(1,i_pt)      &
                               -2 * m%omega_P(3,i_pt) * x%StC_x(2,i_pt)
         enddo

      ELSE IF (p%StC_DOF_MODE == DOFMode_TLCD) THEN !MEG & SP
         ! Compute the first time derivatives of the continuous states of TLCD mode
         do i_pt=1,p%NumMeshPts
            dxdt%StC_x(2,i_pt) = (2*p%rho_X*p%area_X*x%StC_x(1,i_pt)*m%rddot_P(3,i_pt)                                   &
                                   +p%rho_X*p%area_X*p%B_X*m%alpha_P(2,i_pt)*((p%L_X-p%B_X)/2)                        &
                                   -p%rho_X*p%area_X*p%B_X*m%omega_P(1,i_pt)*m%omega_P(3,i_pt)*((p%L_X-p%B_X)/2)      &
                                 +2*p%rho_X*p%area_X*m%omega_P(1,i_pt)*m%omega_P(1,i_pt)*x%StC_x(1,i_pt)*(p%L_X-p%B_X) &
                                 +2*p%rho_X*p%area_X*m%omega_P(2,i_pt)*m%omega_P(2,i_pt)*x%StC_x(1,i_pt)*(p%L_X-p%B_X) &
                                 +2*p%rho_X*p%area_X*x%StC_x(1,i_pt)*m%a_G(3,i_pt)                                       &
                                   -p%rho_X*p%area_X*p%B_X*m%rddot_P(1,i_pt)                                            &
                                   +p%rho_X*p%area_X*p%B_X*m%a_G(1,i_pt)                                                &
                                -.5*p%rho_X*p%area_X*p%headLossCoeff_X*p%area_ratio_X*p%area_ratio_X*x%StC_x(2,i_pt)  &
                                       *ABS(x%StC_x(2,i_pt)))/(p%rho_X*p%area_X*(p%L_X-p%B_X+p%area_ratio_X*p%B_X))        
            dxdt%StC_x(4,i_pt) = (2*p%rho_Y*p%area_Y*x%StC_x(3,i_pt)*m%rddot_P(3,i_pt)                                         &
                                   +p%rho_Y*p%area_Y*p%B_Y*m%alpha_P(1,i_pt)*((p%L_Y-p%B_Y)/2)                              &
                                   -p%rho_Y*p%area_Y*p%B_Y*m%omega_P(2,i_pt)*m%omega_P(3,i_pt)*((p%L_Y-p%B_Y)/2)            &
                                 +2*p%rho_Y*p%area_Y*x%StC_x(3,i_pt)*m%omega_P(1,i_pt)*m%omega_P(1,i_pt)*(p%L_Y-p%B_Y)       &
                                 +2*p%rho_Y*p%area_Y*x%StC_x(3,i_pt)*m%omega_P(2,i_pt)*m%omega_P(2,i_pt)*(p%L_Y-p%B_Y)       &
                                 +2*p%rho_Y*p%area_Y*x%StC_x(3,i_pt)*m%a_G(3,i_pt)-p%rho_Y*p%area_Y*p%B_Y*m%rddot_P(2,i_pt) &
                                   +p%rho_Y*p%area_Y*p%B_Y*m%a_G(2,i_pt)                                                      &
                                -.5*p%rho_Y*p%area_Y*p%headLossCoeff_Y*p%area_ratio_Y*p%area_ratio_Y*x%StC_x(4,i_pt)        &
                                       *ABS(x%StC_x(4,i_pt)))/(p%rho_Y*p%area_Y*(p%L_Y-p%B_Y+p%area_ratio_Y*p%B_Y))
         enddo

      END IF

      call CleanUp()
      return

CONTAINS
   subroutine CleanUp()
   end subroutine CleanUp
   logical function Failed()
        call SetErrStat(ErrStat2, ErrMsg2, ErrStat, ErrMsg, 'StC_CalcContStateDeriv')
        Failed =  ErrStat >= AbortErrLev
        if (Failed) call CleanUp()
   end function Failed
END SUBROUTINE StC_CalcContStateDeriv
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE StC_CalcStopForce(x,p,F_stop)
   TYPE(StC_ContinuousStateType), INTENT(IN   )  :: x           !< Continuous states at Time
   TYPE(StC_ParameterType),       INTENT(IN   )  :: p           !< Parameters
   Real(ReKi), dimension(:,:),    INTENT(INOUT)  :: F_stop      !< stop forces
   ! local variables
   Real(ReKi), dimension(2)                      :: F_SK      !stop spring forces
   Real(ReKi), dimension(2)                      :: F_SD      !stop damping forces
   INTEGER(IntKi)                                :: i         ! counter
   INTEGER(IntKi)                                :: i_pt      ! counter for mesh points
   INTEGER(IntKi)                                :: j         ! counter
   do i_pt=1,p%NumMeshPts
      j=1
      DO i=1,2
         IF (j < 5) THEN
            IF ( x%StC_x(j,i_pt) > p%P_SP(i) ) THEN
               F_SK(i) = p%K_S(i) *( p%P_SP(i) - x%StC_x(j,i_pt)  )
            ELSEIF ( x%StC_x(j,i_pt) < p%N_SP(i) ) THEN
               F_SK(i) = p%K_S(i) * ( p%N_SP(i) - x%StC_x(j,i_pt) )
            ELSE
               F_SK(i)  = 0.0_ReKi
            ENDIF
            IF ( (x%StC_x(j,i_pt) > p%P_SP(i)) .AND. (x%StC_x(j+1,i_pt) > 0) ) THEN
               F_SD(i) = -p%C_S(i) *( x%StC_x(j+1,i_pt)  )
            ELSEIF ( (x%StC_x(j,i_pt) < p%N_SP(i)) .AND. (x%StC_x(j+1,i_pt) < 0) ) THEN
               F_SD(i) = -p%C_S(i) *( x%StC_x(j+1,i_pt)  )
            ELSE
               F_SD(i)  = 0.0_ReKi
            ENDIF
            F_stop(i,i_pt) = F_SK(i) + F_SD(i)
            j = j+2
         END IF
      END DO
   enddo
END SUBROUTINE StC_CalcStopForce
!----------------------------------------------------------------------------------------------------------------------------------
SUBROUTINE StC_GroundHookDamp(dxdt,x,u,p,C_ctrl,C_Brake,F_fr)
   TYPE(StC_ContinuousStateType),         INTENT(IN   )     :: dxdt        !< Derivative of continuous states at Time (needs elements 1 and 3 only)
   TYPE(StC_ContinuousStateType),         INTENT(IN   )     :: x           !< Continuous states at Time
   TYPE(StC_InputType),                   INTENT(IN   )     :: u           !< Inputs at Time
   TYPE(StC_ParameterType),               INTENT(IN)        :: p           !< The module's parameter data
   REAL(ReKi), dimension(:,:),            INTENT(INOUT)     :: C_ctrl      !< extrapolated/interpolated stiffness values
   REAL(ReKi), dimension(:,:),            INTENT(INOUT)     :: C_Brake     !< extrapolated/interpolated stiffness values
   REAL(ReKi), dimension(:,:),            INTENT(INOUT)     :: F_fr        !< Friction forces
   INTEGER(IntKi)                                           :: i_pt        !< generic counter for mesh points

   do i_pt=1,p%NumMeshPts
      IF (p%StC_CMODE == CMODE_Semi .AND. p%StC_SA_MODE == SA_CMODE_GH_vel) THEN ! velocity-based ground hook control with high damping for braking

         !X
         IF (dxdt%StC_x(1,i_pt) * u%Mesh(i_pt)%TranslationVel(1,1) <= 0 ) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
         ELSE
            C_ctrl(1,i_pt) = p%StC_X_C_LOW
         END IF

         !Brake X
         IF      ( (x%StC_x(1,i_pt) > p%P_SP(1)-0.2) .AND. (x%StC_x(2,i_pt) > 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE IF ( (x%StC_x(1,i_pt) < p%N_SP(1)+0.2) .AND. (x%StC_x(2,i_pt) < 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE
            C_Brake(1,i_pt) = 0
         END IF


         ! Y
         IF (dxdt%StC_x(3,i_pt) * u%Mesh(i_pt)%TranslationVel(2,1) <= 0 ) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
         ELSE
            C_ctrl(2,i_pt) = p%StC_Y_C_LOW
         END IF

         !Brake Y
         IF      ( (x%StC_x(3,i_pt) > p%P_SP(2)-0.2) .AND. (x%StC_x(4,i_pt) > 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE IF ( (x%StC_x(3,i_pt) < p%N_SP(2)+0.2) .AND. (x%StC_x(4,i_pt) < 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE
            C_Brake(2,i_pt) = 0
         END IF

      ELSE IF (p%StC_CMODE == CMODE_Semi .AND. p%StC_SA_MODE == SA_CMODE_GH_invVel) THEN ! Inverse velocity-based ground hook control with high damping for braking

         ! X
         IF (dxdt%StC_x(1,i_pt) * u%Mesh(i_pt)%TranslationVel(1,1) >= 0 ) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
         ELSE
            C_ctrl(1,i_pt) = p%StC_X_C_LOW
         END IF

         !Brake X
         IF      ( (x%StC_x(1,i_pt) > p%P_SP(1)-0.2) .AND. (x%StC_x(2,i_pt) > 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE IF ( (x%StC_x(1,i_pt) < p%N_SP(1)+0.2) .AND. (x%StC_x(2,i_pt) < 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE
            C_Brake(1,i_pt) = 0
         END IF

         ! Y
         IF (dxdt%StC_x(3,i_pt) * u%Mesh(i_pt)%TranslationVel(2,1) >= 0 ) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
         ELSE
            C_ctrl(2,i_pt) = p%StC_Y_C_LOW
         END IF

         !Brake Y
         IF      ( (x%StC_x(3,i_pt) > p%P_SP(2)-0.2) .AND. (x%StC_x(4,i_pt) > 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE IF ( (x%StC_x(3,i_pt) < p%N_SP(2)+0.2) .AND. (x%StC_x(4,i_pt) < 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE
            C_Brake(2,i_pt) = 0
         END IF

      ELSE IF (p%StC_CMODE == CMODE_Semi .AND. p%StC_SA_MODE == SA_CMODE_GH_disp) THEN ! displacement-based ground hook control with high damping for braking

         ! X
         IF (dxdt%StC_x(1,i_pt) * u%Mesh(i_pt)%TranslationDisp(1,1) <= 0 ) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
         ELSE
            C_ctrl(1,i_pt) = p%StC_X_C_LOW
         END IF

         !Brake X
         IF      ( (x%StC_x(1,i_pt) > p%P_SP(1)-0.2) .AND. (x%StC_x(2,i_pt) > 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE IF ( (x%StC_x(1,i_pt) < p%N_SP(1)+0.2) .AND. (x%StC_x(2,i_pt) < 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE
            C_Brake(1,i_pt) = 0
         END IF

         ! Y
         IF (dxdt%StC_x(3,i_pt) * u%Mesh(i_pt)%TranslationDisp(2,1) <= 0 ) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
         ELSE
            C_ctrl(2,i_pt) = p%StC_Y_C_LOW
         END IF

         !Brake Y
         IF      ( (x%StC_x(3,i_pt) > p%P_SP(2)-0.2) .AND. (x%StC_x(4,i_pt) > 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE IF ( (x%StC_x(3,i_pt) < p%N_SP(2)+0.2) .AND. (x%StC_x(4,i_pt) < 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE
            C_Brake(2,i_pt) = 0
         END IF

      ELSE IF (p%StC_CMODE == CMODE_Semi .AND. p%StC_SA_MODE == SA_CMODE_Ph_FF) THEN ! Phase Difference Algorithm with Friction Force
            ! X
            ! (a)
         IF      (u%Mesh(i_pt)%TranslationDisp(1,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) < 0 .AND. x%StC_x(1,i_pt) > 0 .AND. dxdt%StC_x(1,i_pt) < 0) THEN
            F_fr(1,i_pt) = p%StC_X_C_HIGH
            ! (b)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) > 0 .AND. x%StC_x(1,i_pt) < 0 .AND. dxdt%StC_x(1,i_pt) > 0) THEN
            F_fr(1,i_pt) = -p%StC_X_C_HIGH
            ! (c)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) < 0 .AND. x%StC_x(1,i_pt) > 0 .AND. dxdt%StC_x(1,i_pt) > 0) THEN
            F_fr(1,i_pt) = -p%StC_X_C_HIGH
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) > 0 .AND. x%StC_x(1,i_pt) < 0 .AND. dxdt%StC_x(1,i_pt) < 0) THEN
            F_fr(1,i_pt) = p%StC_X_C_HIGH
         ELSE
            F_fr(1,i_pt) = p%StC_X_C_LOW
         END IF

         !Brake X
         IF ( (x%StC_x(1,i_pt) > p%P_SP(1)-0.2) .AND. (x%StC_x(2,i_pt) > 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE IF ( (x%StC_x(1,i_pt) < p%N_SP(1)+0.2) .AND. (x%StC_x(2,i_pt) < 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE
            C_Brake(1,i_pt) = 0
         END IF

            ! Y
            ! (a)
         IF      (u%Mesh(i_pt)%TranslationDisp(2,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) < 0 .AND. x%StC_x(3,i_pt) > 0 .AND. dxdt%StC_x(3,i_pt) < 0) THEN
            F_fr(2,i_pt) = p%StC_Y_C_HIGH
            ! (b)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) > 0 .AND. x%StC_x(3,i_pt) < 0 .AND. dxdt%StC_x(3,i_pt) > 0) THEN
            F_fr(2,i_pt) = -p%StC_Y_C_HIGH
            ! (c)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) < 0 .AND. x%StC_x(3,i_pt) > 0 .AND. dxdt%StC_x(3,i_pt) > 0) THEN
            F_fr(2,i_pt) = -p%StC_Y_C_HIGH
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) > 0 .AND. x%StC_x(3,i_pt) < 0 .AND. dxdt%StC_x(3,i_pt) < 0) THEN
            F_fr(2,i_pt) = p%StC_Y_C_HIGH
         ELSE
            F_fr(2,i_pt) = p%StC_Y_C_LOW
         END IF

         !Brake Y
         IF      ( (x%StC_x(3,i_pt) > p%P_SP(2)-0.2) .AND. (x%StC_x(4,i_pt) > 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE IF ( (x%StC_x(3,i_pt) < p%N_SP(2)+0.2) .AND. (x%StC_x(4,i_pt) < 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE
            C_Brake(2,i_pt) = 0
         END IF

      ELSE IF (p%StC_CMODE == CMODE_Semi .AND. p%StC_SA_MODE == SA_CMODE_Ph_DF) THEN ! Phase Difference Algorithm with Damping On/Off
            ! X
            ! (a)
         IF      (u%Mesh(i_pt)%TranslationDisp(1,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) < 0 .AND. x%StC_x(1,i_pt) > 0 .AND. dxdt%StC_x(1,i_pt) < 0) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
            ! (b)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) > 0 .AND. x%StC_x(1,i_pt) < 0 .AND. dxdt%StC_x(1,i_pt) > 0) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
            ! (c)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) < 0 .AND. x%StC_x(1,i_pt) > 0 .AND. dxdt%StC_x(1,i_pt) > 0) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(1,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(1,1) > 0 .AND. x%StC_x(1,i_pt) < 0 .AND. dxdt%StC_x(1,i_pt) < 0) THEN
            C_ctrl(1,i_pt) = p%StC_X_C_HIGH
         ELSE
            C_ctrl(1,i_pt) = p%StC_X_C_LOW
         END IF

         !Brake X
         IF      ( (x%StC_x(1,i_pt) > p%P_SP(1)-0.2) .AND. (x%StC_x(2,i_pt) > 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE IF ( (x%StC_x(1,i_pt) < p%N_SP(1)+0.2) .AND. (x%StC_x(2,i_pt) < 0) ) THEN
            C_Brake(1,i_pt) = p%StC_X_C_BRAKE
         ELSE
            C_Brake(1,i_pt) = 0
         END IF

            ! Y
            ! (a)
         IF      (u%Mesh(i_pt)%TranslationDisp(2,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) < 0 .AND. x%StC_x(3,i_pt) > 0 .AND. dxdt%StC_x(3,i_pt) < 0) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
            ! (b)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) > 0 .AND. x%StC_x(3,i_pt) < 0 .AND. dxdt%StC_x(3,i_pt) > 0) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
            ! (c)
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) < 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) < 0 .AND. x%StC_x(3,i_pt) > 0 .AND. dxdt%StC_x(3,i_pt) > 0) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
         ELSE IF (u%Mesh(i_pt)%TranslationDisp(2,1) > 0 .AND. u%Mesh(i_pt)%TranslationVel(2,1) > 0 .AND. x%StC_x(3,i_pt) < 0 .AND. dxdt%StC_x(3,i_pt) < 0) THEN
            C_ctrl(2,i_pt) = p%StC_Y_C_HIGH
         ELSE
            C_ctrl(2,i_pt) = p%StC_Y_C_LOW
         END IF

         !Brake Y
         IF      ( (x%StC_x(3,i_pt) > p%P_SP(2)-0.2) .AND. (x%StC_x(4,i_pt) > 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE IF ( (x%StC_x(3,i_pt) < p%N_SP(2)+0.2) .AND. (x%StC_x(4,i_pt) < 0) ) THEN
            C_Brake(2,i_pt) = p%StC_Y_C_BRAKE
         ELSE
            C_Brake(2,i_pt) = 0
         END IF

      END IF
   enddo


END SUBROUTINE StC_GroundHookDamp
!----------------------------------------------------------------------------------------------------------------------------------
!> Extrapolate or interpolate stiffness value based on stiffness table.
SUBROUTINE SpringForceExtrapInterp(x, p, F_table,ErrStat,ErrMsg)
   TYPE(StC_ContinuousStateType),         INTENT(IN   )     :: x           !< Continuous states at Time
   TYPE(StC_ParameterType),               INTENT(IN)        :: p           !< The module's parameter data
   REAL(ReKi), dimension(:,:),            INTENT(INOUT)     :: F_table     !< extrapolated/interpolated stiffness values

   INTEGER(IntKi),                        INTENT(OUT)      :: ErrStat        ! The error status code
   CHARACTER(*),                          INTENT(OUT)      :: ErrMsg         ! The error message, if an error occurred

   ! local variables
   INTEGER(IntKi)                                           :: ErrStat2       ! error status
   INTEGER(IntKi)                                           :: I              ! Loop counter
   INTEGER(IntKi), DIMENSION(2)                             :: J = (/1, 3/)   ! Loop counter
   INTEGER(IntKi)                                           :: M              ! location of closest table position
   INTEGER(IntKi)                                           :: Nrows          ! Number of rows in F_TBL
   REAL(ReKi)                                               :: Slope          !
   REAL(ReKi)                                               :: DX             !
   REAL(ReKi)                                               :: Disp(2)        ! Current displacement
   REAL(ReKi), ALLOCATABLE                                  :: TmpRAry(:)
   INTEGER(IntKi)                                           :: i_pt           !< generic counter for mesh point

   ErrStat = ErrID_None
   ErrMsg  = ''

   Nrows = SIZE(p%F_TBL,1)
   ALLOCATE(TmpRAry(Nrows),STAT=ErrStat2)

   do i_pt=1,p%NumMeshPts

      IF (p%StC_DOF_MODE == DOFMode_Indept .OR. p%StC_DOF_MODE == DOFMode_Omni) THEN
         IF (ErrStat2 /= 0) then
             call SetErrStat(ErrID_Fatal,'Error allocating temp array.',ErrStat,ErrMsg,'SpringForceExtrapInterp')
            RETURN
         END IF

         IF (p%StC_DOF_MODE == DOFMode_Indept) THEN
            DO I = 1,2
               Disp(I) = x%StC_x(J(I),i_pt)
            END DO
         ELSE !IF (p%StC_DOF_MODE == DOFMode_Omni) THEN
            Disp = SQRT(x%StC_x(1,i_pt)**2+x%StC_x(3,i_pt)**2) ! constant assignment to vector
         END IF

         DO I = 1,2
            TmpRAry = p%F_TBL(:,J(I))-Disp(I)
            TmpRAry = ABS(TmpRAry)
            M = MINLOC(TmpRAry,1)

            !interpolate
            IF ( (Disp(I) > p%F_TBL(M,J(I)) .AND. M /= Nrows) .OR. (Disp(I) < p%F_TBL(M,J(I)) .AND. M == 1) ) THEN
            ! for displacements higher than the closest table value or lower than the lower bound
               Slope = ( p%F_TBL(M+1,J(I)+1) - p%F_TBL(M,J(I)+1) ) / ( p%F_TBL(M+1,J(I)) - p%F_TBL(M,J(I)) )

            ELSE IF ( (Disp(I) < p%F_TBL(M,J(I)) .AND. M /= 1 ) .OR. (Disp(I) > p%F_TBL(M,J(I)) .AND. M == Nrows) ) THEN ! lower
            ! for displacements lower than the closest table value or higher than the upper bound
               Slope = ( p%F_TBL(M,J(I)+1) - p%F_TBL(M-1,J(I)+1) ) / ( p%F_TBL(M,J(I)) - p%F_TBL(M-1,J(I)) )

            ELSE ! equal
               Slope = 0
            END IF

            F_table(I,i_pt) = p%F_TBL(M,J(I)+1) + Slope * ( Disp(I) - p%F_TBL(M,J(I)) )

         END DO

      END IF
   enddo ! Loop over p%NumMeshPts

   DEALLOCATE(TmpRAry)

END SUBROUTINE SpringForceExtrapInterp
!----------------------------------------------------------------------------------------------------------------------------------
!> This subroutine reads the input file and stores all the data in the StC_InputFile structure.
!! It does not perform data validation.
SUBROUTINE StC_ReadInput( InputFileName, InputFileData, Default_DT, OutFileRoot, ErrStat, ErrMsg )
!..................................................................................................................................

      ! Passed variables
   REAL(DbKi),           INTENT(IN)       :: Default_DT     !< The default DT (from glue code)

   CHARACTER(*), INTENT(IN)               :: InputFileName  !< Name of the input file
   CHARACTER(*), INTENT(IN)               :: OutFileRoot    !< The rootname of all the output files written by this routine.

   TYPE(StC_InputFile),   INTENT(OUT)     :: InputFileData  !< Data stored in the module's input file

   INTEGER(IntKi),       INTENT(OUT)      :: ErrStat        !< The error status code
   CHARACTER(*),         INTENT(OUT)      :: ErrMsg         !< The error message, if an error occurred

      ! local variables

   INTEGER(IntKi)                         :: UnEcho         ! Unit number for the echo file
   INTEGER(IntKi)                         :: ErrStat2       ! The error status code
   CHARACTER(ErrMsgLen)                   :: ErrMsg2        ! The error message, if an error occurred

      ! initialize values:

   ErrStat = ErrID_None
   ErrMsg  = ""

  ! InputFileData%DT = Default_DT  ! the glue code's suggested DT for the module (may be overwritten in ReadPrimaryFile())

      ! get the primary/platform input-file data

   CALL ReadPrimaryFile( InputFileName, InputFileData, OutFileRoot, UnEcho, ErrStat2, ErrMsg2 )
      CALL CheckError(ErrStat2,ErrMsg2)
      IF ( ErrStat >= AbortErrLev ) RETURN


      ! we may need to read additional files here


      ! close any echo file that was opened

   IF ( UnEcho > 0 ) CLOSE( UnEcho )

CONTAINS
   !...............................................................................................................................
   SUBROUTINE CheckError(ErrID,Msg)
   ! This subroutine sets the error message and level and cleans up if the error is >= AbortErrLev
   !...............................................................................................................................

         ! Passed arguments
      INTEGER(IntKi), INTENT(IN) :: ErrID       ! The error identifier (ErrStat)
      CHARACTER(*),   INTENT(IN) :: Msg         ! The error message (ErrMsg)


      !............................................................................................................................
      ! Set error status/message;
      !............................................................................................................................

      IF ( ErrID /= ErrID_None ) THEN

         IF (ErrStat /= ErrID_None) ErrMsg = TRIM(ErrMsg)//NewLine
         ErrMsg = TRIM(ErrMsg)//'StC_ReadInput:'//TRIM(Msg)
         ErrStat = MAX(ErrStat, ErrID)

         !.........................................................................................................................
         ! Clean up if we're going to return on error: close files, deallocate local arrays
         !.........................................................................................................................
         IF ( ErrStat >= AbortErrLev ) THEN
            IF ( UnEcho > 0 ) CLOSE( UnEcho )
         END IF

      END IF


   END SUBROUTINE CheckError

END SUBROUTINE StC_ReadInput
!----------------------------------------------------------------------------------------------------------------------------------
!> This routine reads in the primary ServoDyn input file and places the values it reads in the InputFileData structure.
!! It opens and prints to an echo file if requested.
SUBROUTINE ReadPrimaryFile( InputFile, InputFileData, OutFileRoot, UnEc, ErrStat, ErrMsg )
!..................................................................................................................................

   IMPLICIT                        NONE

      ! Passed variables
   INTEGER(IntKi),     INTENT(OUT)     :: UnEc                                !< I/O unit for echo file. If > 0, file is open for writing.
   INTEGER(IntKi),     INTENT(OUT)     :: ErrStat                             !< Error status

   CHARACTER(*),       INTENT(IN)      :: InputFile                           !< Name of the file containing the primary input data
   CHARACTER(*),       INTENT(OUT)     :: ErrMsg                              !< Error message
   CHARACTER(*),       INTENT(IN)      :: OutFileRoot                         !< The rootname of the echo file, possibly opened in this routine

   TYPE(StC_InputFile), INTENT(INOUT)  :: InputFileData                       !< All the data in the StrucCtrl input file

      ! Local variables:
   REAL(ReKi)                    :: TmpRAry(4)                                ! A temporary array to read a table from the input file
   INTEGER(IntKi)                :: I                                         ! loop counter
   INTEGER(IntKi)                :: UnIn                                      ! Unit number for reading file
   LOGICAL                       :: Echo                                      ! Determines if an echo file should be written

   INTEGER(IntKi)                :: ErrStat2                                  ! Temporary Error status
   CHARACTER(ErrMsgLen)          :: ErrMsg2                                   ! Temporary Error message
   CHARACTER(1024)               :: PriPath                                   ! Path name of the primary file
   CHARACTER(1024)               :: FTitle                                    ! "File Title": the 2nd line of the input file, which contains a description of its contents
   INTEGER(IntKi)                :: NKInpSt                                    ! Number of stiffness input stations in user table
   INTEGER(IntKi)                :: NInputCols                                    ! Number of columns in user-defined stiffness table


      ! Initialize some variables:
   ErrStat = ErrID_None
   ErrMsg  = ""

   UnEc = -1
   Echo = .FALSE.
   CALL GetPath( InputFile, PriPath )     ! Input files will be relative to the path where the primary input file is located.


      ! Get an available unit number for the file.
   CALL GetNewUnit( UnIn, ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN


      ! Open the Primary input file.
   CALL OpenFInpFile ( UnIn, InputFile, ErrStat2, ErrMsg2 )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN


   ! Read the lines up/including to the "Echo" simulation control variable
   ! If echo is FALSE, don't write these lines to the echo file.
   ! If Echo is TRUE, rewind and write on the second try.

   I = 1 !set the number of times we've read the file
   DO
   !-------------------------- HEADER ---------------------------------------------

      CALL ReadCom( UnIn, InputFile, 'File header: Module Version (line 1)', ErrStat2, ErrMsg2, UnEc )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN

      CALL ReadStr( UnIn, InputFile, FTitle, 'FTitle', 'File Header: File Description (line 2)', ErrStat2, ErrMsg2, UnEc )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN

   !---------------------- SIMULATION CONTROL --------------------------------------

      CALL ReadCom( UnIn, InputFile, 'Section Header: Simulation Control', ErrStat2, ErrMsg2, UnEc )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN

         ! Echo - Echo input to "<RootName>.ech".

      CALL ReadVar( UnIn, InputFile, Echo, 'Echo',   'Echo switch', ErrStat2, ErrMsg2, UnEc )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN


      IF (.NOT. Echo .OR. I > 1) EXIT !exit this loop

         ! Otherwise, open the echo file, then rewind the input file and echo everything we've read

      I = I + 1         ! make sure we do this only once (increment counter that says how many times we've read this file)

      CALL OpenEcho ( UnEc, TRIM(OutFileRoot)//'.ech', ErrStat2, ErrMsg2, StC_Ver )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN

      IF ( UnEc > 0 )  WRITE (UnEc,'(/,A,/)')  'Data from '//TRIM(StC_Ver%Name)//' primary input file "'//TRIM( InputFile )//'":'

      REWIND( UnIn, IOSTAT=ErrStat2 )
         IF (ErrStat2 /= 0_IntKi ) THEN
            CALL CheckError( ErrID_Fatal, 'Error rewinding file "'//TRIM(InputFile)//'".' )
            RETURN
         END IF

   END DO


   !------------------ StrucCtrl DEGREES OF FREEDOM -----------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl DEGREES OF FREEDOM', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

    ! StC_DOF_MODE:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_DOF_MODE, "StC_DOF_MODE", "DOF mode {0: NO StC_DOF; 1: StC_X_DOF and StC_Y_DOF; 2: StC_XY_DOF; 3: TLCD} ", ErrStat2, ErrMsg2, UnEc) ! MEG & SP
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_DOF:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_DOF, "StC_X_DOF", "DOF on or off", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_Y_DOF:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_DOF, "StC_Y_DOF", "DOF on or off", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   !------------------ StrucCtrl INITIAL CONDITIONS -----------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl INITIAL CONDITIONS', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_DSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_DSP, "StC_X_DSP", "StC_X initial displacement", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_Y_DSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_DSP, "StC_Y_DSP", "StC_Y initial displacement", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   !------------------ StrucCtrl CONFIGURATION -----------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl CONFIGURATION', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   ! StC_P_X:
   CALL ReadVar(UnIn,InputFile,InputFileData%StC_P_X,"StC_P_X","at rest position of tuned mass damper (X)",ErrStat2,ErrMsg2,UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

    ! StC_P_Y:
   CALL ReadVar(UnIn,InputFile,InputFileData%StC_P_Y,"StC_P_Y","at rest position of tuned mass damper (Y)",ErrStat2,ErrMsg2,UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

    ! StC_P_Z:
   CALL ReadVar(UnIn,InputFile,InputFileData%StC_P_Z,"StC_P_Z","at rest position of tuned mass damper (Z)",ErrStat2,ErrMsg2,UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_PSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_PSP, "StC_X_PSP", "DW stop position (maximum X mass displacement)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_NSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_NSP, "StC_X_NSP", "UW stop position (minimum X mass displacement)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

    ! StC_Y_PSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_PSP, "StC_Y_PSP", "positive lateral stop position (maximum Y mass displacement)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

    ! StC_Y_NSP:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_NSP, "StC_Y_NSP", "negative lateral stop position (minimum Y mass displacement)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   !------------------ StrucCtrl MASS, STIFFNESS, & DAMPING -----------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl MASS, STIFFNESS, & DAMPING', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_X_M:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_M, "StC_X_M", "X tuned mass damper - mass", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_Y_M:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_M, "StC_Y_M", "Y tuned mass damper - mass", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_XY_M:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_XY_M, "StC_XY_M", "XY tuned mass damper - mass", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_X_K:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_K, "StC_X_K", "X tuned mass damper - stiffness", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_Y_K:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_K, "StC_Y_K", "Y tuned mass damper - stiffness", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_X_C:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_C, "StC_X_C", "X tuned mass damper - damping", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_Y_C:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_C, "StC_Y_C", "Y tuned mass damper - damping", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_X_KS:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_KS, "StC_X_KS", "X stop spring stiffness", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_Y_KS:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_KS, "StC_Y_KS", "Y stop spring stiffness", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_X_CS:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_CS, "StC_X_CS", "X stop spring damping", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

      ! StC_Y_CS:
   CALL ReadVar(UnIn,InputFile,InputFileData%StC_Y_CS,"StC_Y_CS","Y stop spring damping",ErrStat2,ErrMsg2,UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   !-------------------------------------------------------------------------------
   !------------------ TLCD -------------------------------------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: TLCD', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )

   ! --------------  FORE-AFT TLCD TOTAL LENGTH, HORIZONTAL LENGTH, VERTICAL AREA, AREA RATIO, DAMPING COEFF, & DENSITY -----
   CALL ReadCom( UnIn, InputFile, 'Section Header: FORE-AFT TLCD TOTAL LENGTH, HORIZONTAL LENGTH, VERTICAL AREA, AREA RATIO, DAMPING COEFF, & DENSITY', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError(ErrStat2, ErrMsg2)
      IF (ErrStat>= AbortErrLev) RETURN

   !Total Length:
   CALL ReadVar (UnIn, InputFile, InputFileData%L_X, "L_X", "Fore-Aft TLCD total length", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Horizontal length:
   CALL ReadVar (UnIn, InputFile, InputFileData%B_X, "B_X", "Fore-Aft TLCD horizontal length", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   ! Vertical area:
   CALL ReadVar (UnIn, InputFile, InputFileData%area_X, "area_X", "Fore-Aft TLCD cross-sectional area of vertical column", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   ! Area ratio:
   CALL ReadVar (UnIn, InputFile, InputFileData%area_ratio_X, "area_ratio_X", "Fore-Aft TLCD cross-sectional area ratio (vertical column area divided by horizontal column area)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Head loss coefficient
   CALL ReadVar (UnIn, InputFile, InputFileData%headLossCoeff_X, "headLossCoeff_X", "Fore-Aft TLCD head loss coeff", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Density
   CALL ReadVar (UnIn, InputFile, InputFileData%rho_X, "rho_X", "Fore-Aft TLCD liquid density", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)
      IF (ErrStat >= AbortErrLev) RETURN

   ! -------------- SIDE-SIDE TLCD TOTAL LENGTH, HORIZONTAL LENGTH, VERTICAL AREA, AREA RATIO, HEAD LOSS COEFF, & DENSITY-----
   CALL ReadCom( UnIn, InputFile, 'Section Header: SIDE-TO-SIDE TLCD TOTAL LENGTH, HORIZONTAL LENGTH, VERTICAL AREA, AREA RATIO, DAMPING COEFF, & DENSITY', ErrStat2, ErrMsg2, UnEc )
   CALL CheckError(ErrStat2, ErrMsg2)
   IF (ErrStat>= AbortErrLev) RETURN

   !Total Length:
   CALL ReadVar (UnIn, InputFile, InputFileData%L_Y, "L_Y", "Side-Side TLCD total length", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Horizontal length:
   CALL ReadVar (UnIn, InputFile, InputFileData%B_Y, "B_Y", "Side-Side TLCD horizontal length", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   ! Vertical area:
   CALL ReadVar (UnIn, InputFile, InputFileData%area_Y, "area_Y", "Side-Side TLCD cross-sectional area of vertical column", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   ! Area ratio:
   CALL ReadVar (UnIn, InputFile, InputFileData%area_ratio_Y, "area_ratio_Y", "Side-Side TLCD cross-sectional area ratio (vertical column area divided by horizontal column area)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Head loss coefficient
   CALL ReadVar (UnIn, InputFile, InputFileData%headLossCoeff_Y, "headLossCoeff_Y", "Side-Side TLCD head loss coeff", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)

   !Density
   CALL ReadVar (UnIn, InputFile, InputFileData%rho_Y, "rho_Y", "Side-Side TLCD liquid density", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError(ErrStat2, ErrMsg2)
      IF (ErrStat >= AbortErrLev) RETURN
   !MEG & SP

   !  -------------- StrucCtrl USER-DEFINED STIFFNESS ---------------------------------

      ! Skip the comment lines.

   CALL ReadCom ( UnIn,  InputFile, 'Section Header: StrucCtrl USER-DEFINED SPRING FORCE', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

     ! Use_F_TBL
   CALL ReadVar( UnIn,  InputFile, InputFileData%Use_F_TBL, "Use_F_TBL", "use spring force from user-defined table (flag)", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! NKInpSt
   CALL ReadVar( UnIn, InputFile, NKInpSt, "NKInpSt", "number of spring force input stations", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   CALL ReadCom ( UnIn, InputFile, 'Section Header: StrucCtrl SPRING FORCE TABLE', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   CALL ReadCom ( UnIn,  InputFile, 'spring force table column names', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

   CALL ReadCom ( UnIn,  InputFile, 'spring force table column units', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! Read the table.

   NInputCols = 4

   ! allocate data for F_TBL
   ALLOCATE (InputFileData%F_TBL(NKInpSt,NInputCols))

   DO I=1,NKInpSt

      CALL ReadAry( UnIn, InputFile, TmpRAry, NInputCols, 'Line'//TRIM(Num2LStr(I)), 'Tuned Mass Damper --  Spring force Properties', &
                    ErrStat2, ErrMsg2, UnEc )
         CALL CheckError( ErrStat2, ErrMsg2 )
         IF ( ErrStat >= AbortErrLev ) RETURN

      InputFileData%F_TBL(I,1) = TmpRAry(1) ! X
      InputFileData%F_TBL(I,2) = TmpRAry(2) ! K_X
      InputFileData%F_TBL(I,3) = TmpRAry(3) ! Y
      InputFileData%F_TBL(I,4) = TmpRAry(4) ! K_Y


   ENDDO ! I
   !------------------ StrucCtrl CONTROL -----------------------------
   CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl CONTROL', ErrStat2, ErrMsg2, UnEc )
      CALL CheckError( ErrStat2, ErrMsg2 )

    ! StC_CMODE:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_CMODE, "StC_CMODE", "control mode {0:none; 1: Semi-Active Control Mode; 2: Active Control Mode;} ", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

    ! StC_SA_MODE:
   CALL ReadVar( UnIn, InputFile, InputFileData%StC_SA_MODE, "StC_SA_MODE", "Semi-Active control mode {1: velocity-based ground hook control; 2: Inverse velocity-based ground hook control; 3: displacement-based ground hook control 4: Phase difference Algorithm with Friction Force 5: Phase difference Algorithm with Damping Force} ", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

    ! StC_X_C_HIGH
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_C_HIGH, "StC_X_C_HIGH", "StrucCtrl X high damping for ground hook control", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_C_LOW
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_C_LOW, "StC_X_C_LOW", "StrucCtrl X low damping for ground hook control", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_Y_C_HIGH
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_C_HIGH, "StC_Y_C_HIGH", "StrucCtrl Y high damping for ground hook control", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_Y_C_HIGH
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_C_LOW, "StC_Y_C_LOW", "StrucCtrl Y high damping for ground hook control", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_X_C_BRAKE
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_X_C_BRAKE, "StC_X_C_BRAKE", "StrucCtrl X high damping for braking the StCX", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN

      ! StC_Y_C_BRAKE
    CALL ReadVar( UnIn, InputFile, InputFileData%StC_Y_C_BRAKE, "StC_Y_C_BRAKE", "StrucCtrl Y high damping for braking the StCY", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN


   !------------------ StrucCtrl Prescribed Forces -------------------
     CALL ReadCom( UnIn, InputFile, 'Section Header: StrucCtrl Prescribed Forces', ErrStat2, ErrMsg2, UnEc )
     CALL CheckError( ErrStat2, ErrMsg2 )

     CALL ReadVar( UnIn, InputFile, InputFileData%PrescribedForcesCoordSys, "PrescribedForcesCoordSys","Prescribed forces coordinate system", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )

     CALL ReadVar( UnIn, InputFile, InputFileData%PrescribedForcesFile, "PrescribedForcesFile","Prescribed input time series", ErrStat2, ErrMsg2, UnEc)
      CALL CheckError( ErrStat2, ErrMsg2 )
      IF ( ErrStat >= AbortErrLev ) RETURN


   !!---------------------- OUTPUT --------------------------------------------------
   !CALL ReadCom( UnIn, InputFile, 'Section Header: Output', ErrStat2, ErrMsg2, UnEc )
   !   CALL CheckError( ErrStat2, ErrMsg2 )
   !   IF ( ErrStat >= AbortErrLev ) RETURN

   !   ! SumPrint - Print summary data to <RootName>.sum (flag):
   !CALL ReadVar( UnIn, InputFile, InputFileData%SumPrint, "SumPrint", "Print summary data to <RootName>.sum (flag)", ErrStat2, ErrMsg2, UnEc)
   !   CALL CheckError( ErrStat2, ErrMsg2 )
   !   IF ( ErrStat >= AbortErrLev ) RETURN

   !!---------------------- OUTLIST  --------------------------------------------
   !   CALL ReadCom( UnIn, InputFile, 'Section Header: OutList', ErrStat2, ErrMsg2, UnEc )
   !   CALL CheckError( ErrStat2, ErrMsg2 )
   !   IF ( ErrStat >= AbortErrLev ) RETURN

      ! OutList - List of user-requested output channels (-):
   !CALL ReadOutputList ( UnIn, InputFile, InputFileData%OutList, InputFileData%NumOuts, 'OutList', "List of user-requested output channels", ErrStat2, ErrMsg2, UnEc  )     ! Routine in NWTC Subroutine Library
   !   CALL CheckError( ErrStat2, ErrMsg2 )
   !   IF ( ErrStat >= AbortErrLev ) RETURN

   !---------------------- END OF FILE -----------------------------------------

   CLOSE ( UnIn )
   RETURN


CONTAINS
   !...............................................................................................................................
   SUBROUTINE CheckError(ErrID,Msg)
   ! This subroutine sets the error message and level
   !...............................................................................................................................

         ! Passed arguments
      INTEGER(IntKi), INTENT(IN) :: ErrID       ! The error identifier (ErrStat)
      CHARACTER(*),   INTENT(IN) :: Msg         ! The error message (ErrMsg)


      !............................................................................................................................
      ! Set error status/message;
      !............................................................................................................................

      IF ( ErrID /= ErrID_None ) THEN

         IF (ErrStat /= ErrID_None) ErrMsg = TRIM(ErrMsg)//NewLine
         ErrMsg = TRIM(ErrMsg)//'ReadPrimaryFile:'//TRIM(Msg)
         ErrStat = MAX(ErrStat, ErrID)

         !.........................................................................................................................
         ! Clean up if we're going to return on error: close file, deallocate local arrays
         !.........................................................................................................................
         IF ( ErrStat >= AbortErrLev ) THEN
            CLOSE( UnIn )
            IF ( UnEc > 0 ) CLOSE ( UnEc )
         END IF

      END IF


   END SUBROUTINE CheckError
   !...............................................................................................................................
END SUBROUTINE ReadPrimaryFile


!----------------------------------------------------------------------------------------------------------------------------------
!> This subroutine checks the data handed in.  If all is good, no errors reported. 
subroutine    StC_ValidatePrimaryData( InputFileData, InitInp, ErrStat, ErrMsg )
   TYPE(StC_InputFile),      INTENT(IN)      :: InputFileData  !< Data stored in the module's input file
   TYPE(StC_InitInputType),  INTENT(IN   )   :: InitInp        !< Input data for initialization routine.
   INTEGER(IntKi),           INTENT(  OUT)   :: ErrStat        !< The error status code
   CHARACTER(ErrMsgLen),     INTENT(  OUT)   :: ErrMsg         !< The error message, if an error occurred

   CHARACTER(*), PARAMETER                   :: RoutineName = 'StC_ValidatePrimaryData'

      ! Initialize variables
   ErrStat = ErrID_None
   ErrMsg  = ''

      ! Check DOF modes
   IF (  InputFileData%StC_DOF_MODE /= ControlMode_None     .and. &
         InputFileData%StC_DOF_MODE /= DOFMode_Indept       .and. &
         InputFileData%StC_DOF_MODE /= DOFMode_Omni         .and. &
         InputFileData%StC_DOF_MODE /= DOFMode_TLCD         .and. &
         InputFileData%StC_DOF_MODE /= DOFMode_Prescribed) &
      CALL SetErrStat( ErrID_Fatal, 'DOF mode (StC_DOF_MODE) must be 0 (no DOF), 1 (two independent DOFs), or 2 (omni-directional), or 3 (TLCD), or 4 (prescribed force time-series).', ErrStat, ErrMsg, RoutineName )

      ! Check control modes
   IF ( InputFileData%StC_CMODE /= ControlMode_None .and. InputFileData%StC_CMODE /= CMODE_Semi ) &
      CALL SetErrStat( ErrID_Fatal, 'Control mode (StC_CMode) must be 0 (none) or 1 (semi-active) in this version of StrucCtrl.', ErrStat, ErrMsg, RoutineName )
!   IF ( InputFileData%StC_CMODE /= ControlMode_None .and. InputFileData%StC_CMODE /= CMODE_Semi .and. InputFileData%StC_CMODE /= CMODE_Active) &
!      CALL SetErrStat( ErrID_Fatal, 'Control mode (StC_CMode) must be 0 (none), 1 (semi-active), or 2 (active).', ErrStat, ErrMsg, RoutineName )

   IF ( InputFileData%StC_SA_MODE /= SA_CMODE_GH_vel    .and. &
        InputFileData%StC_SA_MODE /= SA_CMODE_GH_invVel .and. &
        InputFileData%StC_SA_MODE /= SA_CMODE_GH_disp   .and. &
        InputFileData%StC_SA_MODE /= SA_CMODE_Ph_FF     .and. &
        InputFileData%StC_SA_MODE /= SA_CMODE_Ph_DF     ) then
      CALL SetErrStat( ErrID_Fatal, 'Semi-active control mode (StC_SA_MODE) must be 1 (velocity-based ground hook control), '// &
                   '2 (inverse velocity-based ground hook control), 3 (displacement-based ground hook control), '// &
                   '4 (phase difference algorithm with friction force), or 5 (phase difference algorithm with damping force).', ErrStat, ErrMsg, RoutineName )
   END IF

      ! Prescribed forces
   if (InputFileData%StC_DOF_MODE == DOFMode_Prescribed) then
      if (InputFileData%PrescribedForcesCoordSys /= 0_IntKi .and. InputFileData%PrescribedForcesCoordSys /= 1_IntKi) then
         call SetErrStat( ErrID_Fatal, 'PrescribedForcesCoordSys must be 0 (Global) or 1 (local)', ErrStat, ErrMsg, RoutineName )
      endif
   endif


      ! Check masses make some kind of sense
   if (InputFileData%StC_DOF_MODE == DOFMode_Indept .and. InputFileData%StC_X_DOF .and. (InputFileData%StC_X_M <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_X_M must be > 0 when StC_X_DOF is enabled', ErrStat,ErrMsg,RoutineName)
   if (InputFileData%StC_DOF_MODE == DOFMode_Indept .and. InputFileData%StC_X_DOF .and. (InputFileData%StC_X_K <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_X_K must be > 0 when StC_X_DOF is enabled', ErrStat,ErrMsg,RoutineName)

   if (InputFileData%StC_DOF_MODE == DOFMode_Indept .and. InputFileData%StC_Y_DOF .and. (InputFileData%StC_Y_M <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_Y_M must be > 0 when StC_Y_DOF is enabled', ErrStat,ErrMsg,RoutineName)
   if (InputFileData%StC_DOF_MODE == DOFMode_Indept .and. InputFileData%StC_Y_DOF .and. (InputFileData%StC_Y_K <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_Y_K must be > 0 when StC_Y_DOF is enabled', ErrStat,ErrMsg,RoutineName)

   if (InputFileData%StC_DOF_MODE == DOFMode_Omni .and. (InputFileData%StC_XY_M <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_XY_M must be > 0 when DOF mode 2 (omni-directional) is used', ErrStat,ErrMsg,RoutineName)
   if (InputFileData%StC_DOF_MODE == DOFMode_Omni .and. (InputFileData%StC_X_K <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_X_K must be > 0 when DOF mode 2 (omni-directional) is used', ErrStat,ErrMsg,RoutineName)
   if (InputFileData%StC_DOF_MODE == DOFMode_Omni .and. (InputFileData%StC_Y_K <= 0.0_ReKi) )    & 
      call SetErrStat(ErrID_Fatal,'StC_Y_K must be > 0 when DOF mode 2 (omni-directional) is used', ErrStat,ErrMsg,RoutineName)

      ! Sanity checks for the TLCD option
!FIXME: add some sanity checks here

end subroutine StC_ValidatePrimaryData
!----------------------------------------------------------------------------------------------------------------------------------
!> This subroutine sets the parameters, based on the data stored in InputFileData.
SUBROUTINE StC_SetParameters( InputFileData, InitInp, p, Interval, ErrStat, ErrMsg )
!..................................................................................................................................

   TYPE(StC_InputFile),      INTENT(IN   )   :: InputFileData  !< Data stored in the module's input file
   TYPE(StC_InitInputType),  INTENT(IN   )   :: InitInp        !< Input data for initialization routine.
   TYPE(StC_ParameterType),  INTENT(INOUT)   :: p              !< The module's parameter data
   REAL(DbKi),               INTENT(IN   )   :: Interval       !< Coupling interval in seconds: the rate that
   INTEGER(IntKi),           INTENT(  OUT)   :: ErrStat        !< The error status code
   CHARACTER(ErrMsgLen),     INTENT(  OUT)   :: ErrMsg         !< The error message, if an error occurred

      ! Local variables
   INTEGER(IntKi)                            :: ErrStat2       ! Temporary error ID
   CHARACTER(ErrMsgLen)                      :: ErrMsg2        ! Temporary message describing error
   CHARACTER(*), PARAMETER                   :: RoutineName = 'StC_SetParameters'


      ! Initialize variables
   ErrStat = ErrID_None
   ErrMsg  = ''

      ! Filenames
   p%RootName     =  TRIM(InitInp%RootName)     ! Already includes NStC, TStC, or BStC

      ! Constants
   p%DT  = Interval
   p%Gravity = InitInp%Gravity      ! Gravity vector pointed in negative global Z-axis (/0,0,-g/)
   p%NumMeshPts   =  InitInp%NumMeshPts

      ! DOF controls
   p%StC_DOF_MODE = InputFileData%StC_DOF_MODE

   !p%DT = InputFileData%DT
   !p%RootName = 'StC'
   ! DOFs

   p%StC_X_DOF = InputFileData%StC_X_DOF
   p%StC_Y_DOF = InputFileData%StC_Y_DOF
   p%StC_Z_DOF = InputFileData%StC_Z_DOF

   ! StC X parameters
   p%X_DSP = InputFileData%StC_X_DSP
   p%M_X = InputFileData%StC_X_M
   p%K_X = InputFileData%StC_X_K
   p%C_X = InputFileData%StC_X_C

   ! StC Y parameters
   p%Y_DSP = InputFileData%StC_Y_DSP
   p%M_Y = InputFileData%StC_Y_M
   p%K_Y = InputFileData%StC_Y_K
   p%C_Y = InputFileData%StC_Y_C

   ! StC Z parameters
   p%Z_DSP = InputFileData%StC_Z_DSP
   p%M_Z = InputFileData%StC_Z_M
   p%K_Z = InputFileData%StC_Z_K
   p%C_Z = InputFileData%StC_Z_C

   p%M_XY = InputFileData%StC_XY_M

   ! Fore-Aft TLCD Parameters ! MEG & SP
   p%L_X = InputFileData%L_X
   p%B_X = InputFileData%B_X
   p%area_X = InputFileData%area_X
   p%area_ratio_X = InputFileData%area_ratio_X
   p%headLossCoeff_X = InputFileData%headLossCoeff_X
   p%rho_X = InputFileData%rho_X

   !Side-Side TLCD Parameters
   p%L_Y = InputFileData%L_Y
   p%B_Y = InputFileData%B_Y
   p%area_Y = InputFileData%area_Y
   p%area_ratio_Y = InputFileData%area_ratio_Y
   p%headLossCoeff_Y = InputFileData%headLossCoeff_Y
   p%rho_Y = InputFileData%rho_Y ! MEG & SP

     ! vector parameters
   ! stop positions
   p%P_SP(1) = InputFileData%StC_X_PSP
   p%P_SP(2) = InputFileData%StC_Y_PSP
   p%P_SP(3) = InputFileData%StC_Z_PSP
   p%N_SP(1) = InputFileData%StC_X_NSP
   p%N_SP(2) = InputFileData%StC_Y_NSP
   p%N_SP(3) = InputFileData%StC_Z_NSP
   ! stop force stiffness
   p%K_S(1) = InputFileData%StC_X_KS
   p%K_S(2) = InputFileData%StC_Y_KS
   p%K_S(3) = InputFileData%StC_Z_KS
   ! stop force damping
   p%C_S(1) = InputFileData%StC_X_CS
   p%C_S(2) = InputFileData%StC_Y_CS
   p%C_S(3) = InputFileData%StC_Z_CS

   ! ground hook control damping files
   p%StC_CMODE = InputFileData%StC_CMODE
   p%StC_SA_MODE = InputFileData%StC_SA_MODE
   p%StC_X_C_HIGH = InputFileData%StC_X_C_HIGH
   p%StC_X_C_LOW = InputFileData%StC_X_C_LOW
   p%StC_Y_C_HIGH = InputFileData%StC_Y_C_HIGH
   p%StC_Y_C_LOW = InputFileData%StC_Y_C_LOW
   p%StC_Z_C_HIGH = InputFileData%StC_Z_C_HIGH
   p%StC_Z_C_LOW = InputFileData%StC_Z_C_LOW
   p%StC_X_C_BRAKE = InputFileData%StC_X_C_BRAKE
   p%StC_Y_C_BRAKE = InputFileData%StC_Y_C_BRAKE
   p%StC_Z_C_BRAKE = InputFileData%StC_Z_C_BRAKE

   ! User Defined Stiffness Table
   p%Use_F_TBL = InputFileData%Use_F_TBL
   ALLOCATE (p%F_TBL(SIZE(InputFiledata%F_TBL,1),SIZE(InputFiledata%F_TBL,2)), STAT=ErrStat2)
   IF (ErrStat2/=0) THEN
      CALL SetErrStat(ErrID_Fatal,"Error allocating p%F_TBL.",ErrStat,ErrMsg,RoutineName)
      RETURN
   END IF

   p%F_TBL = InputFileData%F_TBL;

   if ( p%StC_DOF_MODE == DOFMode_Prescribed ) then
      call Read_ForceTimeSeriesFile(InputFileData%PrescribedForcesFile,p%StC_PrescribedForce,ErrStat2,ErrMsg2)
      call SetErrStat(ErrStat2,ErrMsg2, ErrStat,ErrMsg, RoutineName)
   endif

   p%PrescribedForcesCoordSys =  InputFileData%PrescribedForcesCoordSys


END SUBROUTINE StC_SetParameters




subroutine Read_ForceTimeSeriesFile(ForceFilename,ForceArray,ErrStat,ErrMsg)
   character(*),            intent(in   ) :: ForceFileName
   real(ReKi), allocatable, intent(  out) :: ForceArray(:,:)
   integer(IntKi),          intent(  out) :: ErrStat
   character(ErrMsgLen),    intent(  out) :: ErrMsg

   character(1024)                        :: ErrMsgTmp            !< Temporary error message for calls
   integer(IntKi)                         :: ErrStatTmp           !< Temporary error status for calls
   integer(IntKi)                         :: FiD         !< Unit number for points file to open
   integer(IntKi)                         :: NumDataColumns       !< Number of data columns
   integer(IntKi)                         :: NumDataPoints        !< Number of lines of data (one point per line)
   integer(IntKi)                         :: NumHeaderLines       !< Number of header lines to ignore
   integer(IntKi)                         :: I                    !< Generic counter
   character(*), parameter                :: RoutineName='Read_ForceTimeSeriesFile'

      ! Initialization of subroutine
   ErrMsg      =  ''
   ErrMsgTmp   =  ''
   ErrStat     =  ErrID_None
   ErrStatTmp  =  ErrID_None

      ! Now open file
   call GetNewUnit(    FiD )
   call OpenFInpFile(   FiD,  trim(ForceFileName), ErrStatTmp, ErrMsgTmp )   ! Unformatted input file
   if ( ErrStatTmp >= AbortErrLev ) then
      call SetErrStat( ErrStatTmp, ErrMsgTmp, ErrStat, ErrMsg, RoutineName)
      close( FiD )
      return
   endif

      ! Find out how long the file is
   call GetFileLength( FiD, ForceFileName, NumDataColumns, NumDataPoints, NumHeaderLines, ErrMsgTmp, ErrStatTmp )
   if ( ErrStatTmp >= AbortErrLev ) then
      call SetErrStat( ErrStatTmp, ErrMsgTmp, ErrStat, ErrMsg, RoutineName)
      close( FiD )
      return
   endif
   if ( NumDataColumns /= 7 ) then
      CALL SetErrStat( ErrID_Fatal,' Expecting 7 columns in '//TRIM(ForceFileName)//' corresponding to '//   &
         'X, Y, and Z coordinates.  Instead found '//TRIM(Num2LStr(NumDataColumns))//'.', &
         ErrStat, ErrMsg, RoutineName)
      close( FiD )
      return
   endif

      ! Allocate the storage for the data
   call AllocAry( ForceArray, 7, NumDataPoints, "Array of Points data", ErrStatTmp, ErrMsgTmp )
   if ( ErrStatTmp >= AbortErrLev ) then
      call SetErrStat( ErrStatTmp, ErrMsgTmp, ErrStat, ErrMsg, RoutineName)
      close( FiD )
      return
   endif

      ! Read in the headers and throw them away
   do I=1,NumHeaderLines
      call ReadCom( FiD, ForceFileName,' Points file header line', ErrStatTmp, ErrMsgTmp )
      if ( ErrStatTmp /= ErrID_None ) then
         call SetErrStat(ErrID_Fatal,ErrMsgTmp,ErrStat,ErrMsg,RoutineName)
         close( FiD )
         return
      endif
   enddo

      ! Read in the datapoints
   do I=1,NumDataPoints
      call ReadAry ( FiD, ForceFileName, ForceArray(:,I), 7, 'ForceArray', &
         'Coordinate point from Points file', ErrStatTmp, ErrMsgTmp)
      if ( ErrStat /= ErrID_None ) THEN
         call SetErrStat( ErrID_Fatal,ErrMsgTmp,ErrStat,ErrMsg,RoutineName)
         close( FiD )
         return
      endif
   enddo

   close( FiD )

contains

  !-------------------------------------------------------------------------------------------------------------------------------
   !>    This subroutine looks at a file that has been opened and finds out how many header lines there are, how many columns there
   !!    are, and    how many lines of data there are in the file.
   !!
   !!    A few things are assumed about the file:
   !!       1. Any header lines are the first thing in the file.
   !!       2. No text appears anyplace other than in first part of the file
   !!       3. The datalines only contain numbers that can be read in as reals.
   !!
   !!    Limitations:
   !!       1. only handles up to 20 words (columns) on a line
   !!       2. empty lines are considered text lines
   !!       3. All data rows must contain the same number of columns
   !!
   !!
   subroutine GetFileLength(UnitDataFile, DataFileName, NumDataColumns, NumDataLines, NumHeaderLines, ErrMsg, ErrStat)
      integer(IntKi),                     intent(in   )  :: UnitDataFile      !< Unit number of the file we are looking at.
      character(*),                       intent(in   )  :: DataFileName      !< The name of the file we are looking at.
      integer(IntKi),                     intent(  out)  :: NumDataColumns    !< The number of columns in the data file.
      integer(IntKi),                     intent(  out)  :: NumDataLines      !< Number of lines containing data
      integer(IntKi),                     intent(  out)  :: NumHeaderLines    !< Number of header lines at the start of the file
      character(*),                       intent(  out)  :: ErrMsg            !< Error Message to return (empty if all good)
      integer(IntKi),                     intent(  out)  :: ErrStat           !< Status flag if there were any problems (ErrID_None if all good)

         ! Local Variables
      character(2048)                                    :: ErrMsgTmp         !< Temporary message variable.  Used in calls.
      integer(IntKi)                                     :: ErrStatTmp        !< Temporary error status.  Used in calls.
      integer(IntKi)                                     :: LclErrStat        !< Temporary error status.  Used locally to indicate when we have reached the end of the file.
      integer(IntKi)                                     :: TmpIOErrStat      !< Temporary error status for the internal read of the first word to a real number
      logical                                            :: IsRealNum         !< Flag indicating if the first word on the line was a real number

      character(1024)                                    :: TextLine          !< One line of text read from the file
      integer(IntKi)                                     :: LineLen           !< The length of the line read in
      character(1024)                                    :: StrRead           !< String containing the first word read in
      real(ReKi)                                         :: RealRead          !< Returns value of the number (if there was one), or NaN (as set by NWTC_Num) if there wasn't
      character(1024)                                    :: VarName           !< Name of the variable we are trying to read from the file
      character(24)                                      :: Words(20)         !< Array of words we extract from a line.  We shouldn't have more than 20.
      integer(IntKi)                                     :: i,j,k             !< simple integer counters
      integer(IntKi)                                     :: LineNumber        !< the line I am on
      logical                                            :: LineHasText       !< Flag indicating if the line I just read has text.  If so, it is a header line.
      logical                                            :: HaveReadData      !< Flag indicating if I have started reading data.
      integer(IntKi)                                     :: NumWords          !< Number of words on a line
      integer(IntKi)                                     :: FirstDataLineNum  !< Line number of the first row of data in the file

         ! Initialize the error handling
      ErrStat     = ErrID_None
      ErrStatTmp  = ErrID_None
      LclErrStat  = ErrID_None
      ErrMsg      = ''
      ErrMsgTmp   = ''

         ! Set some of the flags and counters
      HaveReadData   = .FALSE.
      NumDataColumns = 0
      NumHeaderLines = 0
      NumDataLines   = 0
      LineNumber     = 0

         ! Just in case we were handed a file that we are part way through reading (should never be true), rewind to the start
      rewind( UnitDataFile )

      !------------------------------------
      !> The variable LclErrStat is used to indicate when we have reached the end of the file or had an error from
      !! ReadLine.  Until that occurs, we read each line, and decide if it contained any non-numeric data.  The
      !! first group of lines containing non-numeric data is considered the header.  The first line of all numeric
      !! data is considered the start of the data section.  Any non-numeric containing found within the data section
      !! will be considered as an invalid file format at which point we will return a fatal error from this routine.
      do while ( LclErrStat == ErrID_None )

            !> Reset the indicator flag for the non-numeric content
         LineHasText = .FALSE.

            !> Read in a single line from the file
         call ReadLine( UnitDataFile, '', TextLine, LineLen, LclErrStat )

            !> If there was an error in reading the file, then exit.
            !!    Possible causes: reading beyond end of file in which case we are done so don't process it.
         if ( LclErrStat /= ErrID_None ) exit

            !> Increment the line counter.
         LineNumber  = LineNumber + 1

            !> Read all the words on the line into the array called 'Words'.  Only the first words will be encountered
            !! will be stored.  The others are empty (i.e. only three words on the line, so the remaining 17 are empty).
         call GetWords( TextLine, Words, 20 )

            !> Cycle through and count how many are not empty.  Once an empty value is encountered, all the rest should
            !! be empty if GetWords worked correctly.  The index of the last non-empty value is stored.
         do i=1,20
            if (TRIM(Words(i)) .ne. '') NumWords=i
         enddo


            !> Now cycle through the first 'NumWords' of non-empty values stored in 'Words'.  Words should contain
            !! everything that is one the line.  The subroutine ReadRealNumberFromString will set a flag 'IsRealNum'
            !! when the value in Words(i) can be read as a real(ReKi).  'StrRead' will contain the string equivalent.
         do i=1,NumWords
            CALL ReadRealNumberFromString( Words(i), RealRead, StrRead, IsRealNum, ErrStatTmp, ErrMsgTmp, TmpIOErrStat )
            if ( .not. IsRealNum) LineHasText = .TRUE.
         enddo

            !> If all the words on that line had no text in them, then it must have been a line of data.
            !! If not, then we have either a header line, which is ok, or a line containing text in the middle of the
            !! the data section, which is not good (the flag HaveReadData tells us which case this is).
         if ( LineHasText ) then
            if ( HaveReadData ) then      ! Uh oh, we have already read a line of data before now, so there is a problem
               call SetErrStat( ErrID_Fatal, ' Found text on line '//TRIM(Num2LStr(LineNumber))//' of '//TRIM(DataFileName)// &
                           ' when real numbers were expected.  There may be a problem with format of the file: '// &
                           TRIM(DataFileName)//'.', ErrStat, ErrMsg, 'GetFileLength')
               if ( ErrStat >= AbortErrLev ) return
            else
               NumHeaderLines = NumHeaderLines + 1
            endif
         else     ! No text, must be data line
            NumDataLines = NumDataLines + 1
               ! If this is the first row of data, then store the number of words that were on the line
            if ( .not. HaveReadData )  then
                  ! If this is the first line of data, keep some relevant info about it and the number of columns in it
               HaveReadData      = .TRUE.
               FirstDataLineNum  = LineNumber         ! Keep the line number of the first row of data (for error reporting)
               NumDataColumns    = NumWords
            else
                  ! Make sure that the number columns on the row matches the number of columnns on the first row of data.
               if ( NumWords /= NumDataColumns ) then
                  call SetErrStat( ErrID_Fatal, ' Error in file: '//TRIM(DataFileName)//'.'// &
                           ' The number of data columns on line '//TRIM(Num2LStr(LineNumber))// &
                           '('//TRIM(Num2LStr(NumWords))//' columns) is different than the number of columns on first row of data '// &
                           ' (line: '//TRIM(Num2LStr(FirstDataLineNum))//', '//TRIM(Num2LStr(NumDataColumns))//' columns).', &
                           ErrStat, ErrMsg, 'GetFileLength')
                  if ( ErrStat >= AbortErrLev ) return
               endif
            endif
         endif
      enddo
      rewind( UnitDataFile )
   end subroutine GetFileLength

   !-------------------------------------------------------------------------------
   !> This subroutine takes a line of text that is passed in and reads the first
   !! word to see if it is a number.  An internal read is used to do this.  If
   !! it is a number, it is started in ValueRead and returned. The flag IsRealNum
   !! is set to true.  Otherwise, ValueRead is set to NaN (value from the NWTC_Num)
   !! and the flag is set to false.
   !!
   !! The IsRealNum flag is set to indicate if we actually have a real number or
   !! not.  After calling this routine, a simple if statement can be used:
   !!
   !!       @code
   !!    IF (IsRealNum) THEN
   !!       ! do something
   !!    ELSE
   !!       ! do something else
   !!    ENDIF
   !!       @endcode
   !!
   !-------------------------------------------------------------------------------
   subroutine ReadRealNumberFromString(StringToParse, ValueRead, StrRead, IsRealNum, ErrStat, ErrMsg, IOErrStat)
      character(*),        intent(in   )           :: StringToParse  !< The string we were handed.
      real(ReKi),          intent(  out)           :: ValueRead      !< The variable being read.  Returns as NaN (library defined) if not a Real.
      character(*),        intent(  out)           :: StrRead        !< A string containing what was read from the ReadNum routine.
      logical,             intent(  out)           :: IsRealNum      !< Flag indicating if we successfully read a Real
      integer(IntKi),      intent(  out)           :: ErrStat        !< ErrID level returned from ReadNum
      character(*),        intent(  out)           :: ErrMsg         !< Error message including message from ReadNum
      integer(IntKi),      intent(  out)           :: IOErrStat      !< Error status from the internal read. Useful for diagnostics.

         ! Initialize some things
      ErrStat     = ErrID_None
      ErrMsg      = ''

         ! ReadNum returns a string contained in StrRead.  So, we now try to do an internal read to VarRead and then trap errors.
      read(StringToParse,*,IOSTAT=IOErrStat)   StrRead
      read(StringToParse,*,IOSTAT=IOErrStat)   ValueRead

         ! If IOErrStat==0, then we have a real number, anything else is a problem.
      if (IOErrStat==0) then
         IsRealNum   = .TRUE.
      else
         IsRealNum   = .FALSE.
         ValueRead   = NaN                ! This is NaN as defined in the NWTC_Num.
         ErrMsg      = 'Not a real number. '//TRIM(ErrMsgTmp)//NewLine
         ErrSTat     = ErrID_Severe
      endif
      return
   end subroutine ReadRealNumberFromString
end subroutine Read_ForceTimeSeriesFile

!----------------------------------------------------------------------------------------------------------------------------------
END MODULE StrucCtrl
!**********************************************************************************************************************************
