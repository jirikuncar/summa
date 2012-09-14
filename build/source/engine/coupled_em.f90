module coupled_em_module
USE nrtype
implicit none
private
public::coupled_em
contains

 ! ************************************************************************************************
 ! new subroutine: run the coupled energy-mass model for one timestep
 ! ************************************************************************************************
 subroutine coupled_em(dt_init,err,message)
 USE data_struc,only:forcFileInfo                                     ! extract time step of forcing data
 USE data_struc,only:model_decisions                                  ! model decision structure
 USE data_struc,only:mpar_data,mvar_data,indx_data,ix_soil,ix_snow    ! data structures
 USE var_lookup,only:iLookDECISIONS                                   ! named variables for elements of the decision structure
 USE var_lookup,only:iLookPARAM,iLookMVAR,iLookINDEX                  ! named variables for structure elements
 USE newsnwfall_module,only:newsnwfall      ! compute new snowfall
 USE layerMerge_module,only:layerMerge      ! merge snow layers if they are too thin
 USE picardSolv_module,only:picardSolv      ! provide access to the Picard solver
 USE multiconst,only:iden_water,iden_ice    ! intrinsic density of water and icei
 implicit none
 ! define output
 real(dp),intent(inout)               :: dt_init              ! used to initialize the size of the sub-step
 integer(i4b),intent(out)             :: err                  ! error code
 character(*),intent(out)             :: message              ! error message
 ! control the length of the sub-step
 real(dp)                             :: dt                   ! length of time step (seconds)
 real(dp)                             :: dt_sub               ! length of the sub-step (seconds)
 real(dp)                             :: dt_done              ! length of time step completed (seconds)
 integer(i4b)                         :: nsub                 ! number of sub-steps
 integer(i4b)                         :: niter                ! number of iterations
 integer(i4b),parameter               :: n_inc=5              ! minimum number of iterations to increase time step
 integer(i4b),parameter               :: n_dec=9              ! maximum number of iterations to decrease time step
 real(dp),parameter                   :: F_inc = 1.25_dp      ! factor used to increase time step
 real(dp),parameter                   :: F_dec = 0.5_dp       ! factor used to decrease time step
 integer(i4b)                         :: maxiter              ! maxiumum number of iterations
 integer(i4b)                         :: iSnow                ! index for snow layers
 ! local pointers to model forcing data
 real(dp),pointer                     :: scalarRainfall       ! rainfall flux (kg m-2 s-1)
 real(dp),pointer                     :: scalarSnowfall       ! snowfall flux (kg m-2 s-1)
 ! local pointers to model index variables
 integer(i4b),pointer                 :: nSoil                ! number of soil layers
 integer(i4b),pointer                 :: nSnow                ! number of snow layers
 integer(i4b),pointer                 :: nLayers              ! number of layers
 integer(i4b),pointer                 :: layerType(:)         ! type of the layer (ix_soil or ix_snow)
 ! local pointers to model state variables -- all layers
 real(dp),pointer                     :: mLayerTemp(:)        ! temperature of each layer (K)
 real(dp),pointer                     :: mLayerDepth(:)       ! depth of each layer (m)
 real(dp),pointer                     :: mLayerVolFracIce(:)  ! volumetric fraction of ice in each layer (-)
 real(dp),pointer                     :: mLayerVolFracLiq(:)  ! volumetric fraction of liquid water in each layer (-) 
 ! local pointers to flux variables
 real(dp),pointer                     :: scalarMassLiquid     ! evaporation or dew (kg m-2 s-1)
 real(dp),pointer                     :: scalarMassSolid      ! sublimation or frost (kg m-2 s-1)
 real(dp),pointer                     :: scalarRainPlusMelt   ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 real(dp),pointer                     :: scalarSurfaceRunoff  ! surface runoff (m s-1) 
 real(dp),pointer                     :: scalarSoilInflux     ! influx of water at the top of the soil profile (m s-1)
 real(dp),pointer                     :: scalarSoilDrainage   ! drainage from the bottom of the soil profile (m s-1)
 ! local pointers to timestep-average flux variables
 real(dp),pointer                     :: averageMassLiquid    ! evaporation or dew (kg m-2 s-1)
 real(dp),pointer                     :: averageMassSolid     ! sublimation or frost (kg m-2 s-1)
 real(dp),pointer                     :: averageRainPlusMelt  ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 real(dp),pointer                     :: averageSurfaceRunoff ! surface runoff (m s-1) 
 real(dp),pointer                     :: averageSoilInflux    ! influx of water at the top of the soil profile (m s-1)
 real(dp),pointer                     :: averageSoilDrainage  ! drainage from the bottom of the soil profile (m s-1)
 ! local pointers to algorithmic control parameters
 real(dp),pointer                     :: minstep              ! minimum time step length (s)
 real(dp),pointer                     :: maxstep              ! maximum time step length (s)
 ! define local variables
 character(len=256)                   :: cmessage             ! error message
 real(dp),dimension(:),allocatable    :: arrTemp              ! temporary array, used for testing
 integer(i4b)                         :: iLayer               ! index of model layers
 ! initialize error control
 err=0; message="coupled_em/"

 ! assign pointers to model diagnostic variables -- surface scalars 
 scalarRainfall    => mvar_data%var(iLookMVAR%scalarRainfall)%dat(1)     ! rainfall flux (kg m-2 s-1)
 scalarSnowfall    => mvar_data%var(iLookMVAR%scalarSnowfall)%dat(1)     ! snowfall flux (kg m-2 s-1)

 ! assign pointers to timestep-average model fluxes
 averageMassLiquid     => mvar_data%var(iLookMVAR%averageMassLiquid)%dat(1)      ! evaporation or dew (kg m-2 s-1)
 averageMassSolid      => mvar_data%var(iLookMVAR%averageMassSolid)%dat(1)       ! sublimation or frost (kg m-2 s-1)
 averageRainPlusMelt   => mvar_data%var(iLookMVAR%averageRainPlusMelt)%dat(1)    ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 averageSurfaceRunoff  => mvar_data%var(iLookMVAR%averageSurfaceRunoff)%dat(1)   ! surface runoff (m s-1)
 averageSoilInflux     => mvar_data%var(iLookMVAR%averageSoilInflux)%dat(1)      ! influx of water at the top of the soil profile (m s-1)
 averageSoilDrainage   => mvar_data%var(iLookMVAR%averageSoilDrainage)%dat(1)    ! drainage from the bottom of the soil profile (m s-1)

 ! assign pointers to algorithmic control parameters
 minstep => mpar_data%var(iLookPARAM%minstep)  ! minimum time step (s)
 maxstep => mpar_data%var(iLookPARAM%maxstep)  ! maximum time step (s)
 !print*, 'minstep, maxstep = ', minstep, maxstep

 ! initialize average fluxes
 averageSurfaceRunoff  = 0._dp  ! surface runoff (m s-1)
 averageMassLiquid     = 0._dp  ! evaporation or dew (kg m-2 s-1)
 averageMassSolid      = 0._dp  ! sublimation or frost (kg m-2 s-1)
 averageRainPlusMelt   = 0._dp  ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 averageSoilInflux     = 0._dp  ! influx of water at the top of the soil profile (m s-1)
 averageSoilDrainage   = 0._dp  ! drainage from the bottom of the soil profile (m s-1)

 ! get the length of the time step (seconds)
 dt = forcFileInfo%data_step

 ! identify the maximum number of iterations
 select case(trim(model_decisions(iLookDECISIONS%num_method)%decision))
  case('itertive'); maxiter=nint(mpar_data%var(iLookPARAM%maxiter))  ! iterative
  case('non_iter'); maxiter=1              ! non-iterative
  case('itersurf'); maxiter=1              ! iterate only on the surface energy balance
   err=90; message=trim(message)//'numerical method "itersurf" is not implemented yet'; return
  case default
   err=10; message=trim(message)//'unknown option for the numerical method'; return
 end select

 ! initialize the length of the sub-step
 dt_sub  = min(dt_init,dt)
 dt_done = 0._dp

 ! initialize the number of sub-steps
 nsub=0

 ! loop through sub-steps
 do  ! continuous do statement with exit clause (alternative to "while")

  ! increment the number of sub-steps
  nsub = nsub+1

  if(scalarSnowfall > 0._dp)then
   call newsnwfall(dt_sub,            & ! time step (seconds)
                   err,cmessage)        ! error control
   if(err/=0)then; err=55; message=trim(message)//trim(cmessage); return; endif
   !print*, 'scalarRainfall, scalarSnowfall = ', scalarRainfall, scalarSnowfall
   !stop ' snow is falling!'
  endif

  ! merge snow layers if they are too thin
  call layerMerge(err,cmessage)        ! error control
  if(err/=0)then; err=65; message=trim(message)//trim(cmessage); return; endif

  ! assign local pointers to the model index structures
  nSoil             => indx_data%var(iLookINDEX%nSoil)%dat(1)             ! number of soil layers
  nSnow             => indx_data%var(iLookINDEX%nSnow)%dat(1)             ! number of snow layers
  nLayers           => indx_data%var(iLookINDEX%nLayers)%dat(1)           ! total number of layers
  layerType         => indx_data%var(iLookINDEX%layerType)%dat            ! layer type (ix_soil or ix_snow)

  ! identify the number of snow and soil layers
  nSnow = count(layerType==ix_snow)
  nSoil = count(layerType==ix_soil)

  ! assign pointers to model state variables -- all layers
  mLayerTemp        => mvar_data%var(iLookMVAR%mLayerTemp)%dat            ! temperature of each layer (K)
  mLayerDepth       => mvar_data%var(iLookMVAR%mLayerDepth)%dat           ! depth of each layer (m)
  mLayerVolFracIce  => mvar_data%var(iLookMVAR%mLayerVolFracIce)%dat      ! volumetric fraction of ice in each layer (-)
  mLayerVolFracLiq  => mvar_data%var(iLookMVAR%mLayerVolFracLiq)%dat      ! volumetric fraction of liquid water in each layer (-)

  ! assign pointers to the model flux variables
  scalarMassLiquid    => mvar_data%var(iLookMVAR%scalarMassLiquid)%dat(1)      ! evaporation or dew (kg m-2 s-1)
  scalarMassSolid     => mvar_data%var(iLookMVAR%scalarMassSolid)%dat(1)       ! sublimation or frost (kg m-2 s-1)
  scalarRainPlusMelt  => mvar_data%var(iLookMVAR%scalarRainPlusMelt)%dat(1)    ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
  scalarSurfaceRunoff => mvar_data%var(iLookMVAR%scalarSurfaceRunoff)%dat(1)   ! surface runoff (m s-1)
  scalarSoilInflux    => mvar_data%var(iLookMVAR%scalarSoilInflux)%dat(1)      ! influx of water at the top of the soil profile (m s-1)
  scalarSoilDrainage  => mvar_data%var(iLookMVAR%scalarSoilDrainage)%dat(1)    ! drainage from the bottom of the soil profile (m s-1)

  ! allocate temporary array
  allocate(arrTemp(nLayers),stat=err)
  if(err/=0)then; err=20; message='problem allocating space for temporary array'; return; endif

  ! save the volumetric fraction of ice
  arrTemp = mLayerDepth

  ! use Picard iteration to solve model equations
  do
   ! get the new solution
   call picardSolv(dt_sub,maxiter,niter,err,cmessage)
   if(err>0)then; message=trim(message)//trim(cmessage); return; endif
   !if(err<0)then; message=trim(message)//trim(cmessage); return; endif 
   ! exit do loop if all is a-ok
   if(err==0) exit
   ! if not ok, reduce time step and try again
   dt_sub = dt_sub*0.1_dp
   print*, dt_sub, minstep, trim(message)//trim(cmessage)
   ! check that the step size is still appropriate -- if not, use non-iterative solution
   if(dt_sub < minstep)then
    if(err/=0)then; message=trim(message)//'dt_sub is below the minimum time step'; return; endif
    dt_sub  = minstep
    call picardSolv(dt_sub,1,niter,err,cmessage) ! just iterate once
    if(err/=0)then; message=trim(message)//trim(cmessage); return; endif
    exit ! exit do loop if all is a-ok
   endif
  end do 

  ! increment timestep-average fluxes
  averageMassLiquid     = averageMassLiquid    + scalarMassLiquid*dt_sub    ! evaporation or dew (kg m-2 s-1)
  averageMassSolid      = averageMassSolid     + scalarMassSolid*dt_sub     ! sublimation or frost (kg m-2 s-1)
  averageRainPlusMelt   = averageRainPlusMelt  + scalarRainPlusMelt*dt_sub  ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
  averageSurfaceRunoff  = averageSurfaceRunoff + scalarSurfaceRunoff*dt_sub ! surface runoff (m s-1)
  averageSoilInflux     = averageSoilInflux    + scalarSoilInflux*dt_sub    ! influx of water at the top of the soil profile (m s-1)
  averageSoilDrainage   = averageSoilDrainage  + scalarSoilDrainage*dt_sub  ! drainage from the bottom of the soil profile (m s-1)

  ! check that snow depth is decreasing (can only increase in the top layer)
  if(nSnow>1)then
   do iSnow=2,nSnow
    if(mLayerDepth(iSnow) > arrTemp(iSnow)+1.e-8_dp)then
     write(*,'(a,1x,100(f20.10))') 'depth1 = ', arrTemp(1:nSnow)
     write(*,'(a,1x,100(f20.10))') 'depth2 = ', mLayerDepth(1:nSnow)
     write(*,'(a,1x,100(f20.10))') 'diff   = ', mLayerDepth(1:nSnow) - arrTemp(1:nSnow)
     stop 'depth is increasing '
    endif
   end do ! looping thru snow layers
  endif

  ! increment the time step increment
  dt_done = dt_done + dt_sub
  !print*, '***** ', dt_done, dt_sub, niter

  ! modify the length of the time step
  if(niter<n_inc) dt_sub = dt_sub*F_inc
  if(niter>n_dec) dt_sub = dt_sub*F_dec

  ! save the time step to initialize the subsequent step
  if(dt_done<dt .or. nsub==1) dt_init = dt_sub
  if(dt_init < 0.001_dp .and. nsub > 1000) then
   write(message,'(a,f13.10,a,f9.2,a,i0,a)')trim(message)//"dt < 0.001 and nsub > 1000 [dt=",dt_init,"; dt_done=",&
         dt_done,"; nsub=",nsub,"]"
   err=20; return
  endif

  ! exit do-loop if finished
  if(dt_done>=dt)exit

  ! make sure that we don't exceed the step
  dt_sub = min(dt-dt_done, dt_sub)
  
  ! deallocate temporary array
  deallocate(arrTemp,stat=err)
  if(err/=0)then; err=20; message='problem deallocating space for temporary array'; return; endif

 end do  ! (sub-step loop)

 ! convert total fluxes to average fluxes
 averageMassLiquid     = averageMassLiquid    /dt ! evaporation or dew (kg m-2 s-1)
 averageMassSolid      = averageMassSolid     /dt ! sublimation or frost (kg m-2 s-1)
 averageRainPlusMelt   = averageRainPlusMelt  /dt ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 averageSurfaceRunoff  = averageSurfaceRunoff /dt ! surface runoff (m s-1)
 averageSoilInflux     = averageSoilInflux    /dt ! influx of water at the top of the soil profile (m s-1)
 averageSoilDrainage   = averageSoilDrainage  /dt ! drainage from the bottom of the soil profile (m s-1)

 ! save the surface temperature (just to make things easier to visualize)
 mvar_data%var(iLookMVAR%scalarSurfaceTemp)%dat(1) = mvar_data%var(iLookMVAR%mLayerTemp)%dat(1)

 iLayer = nSnow+1
 !print*, 'nsub, mLayerTemp(iLayer), mLayerVolFracIce(iLayer) = ', nsub, mLayerTemp(iLayer), mLayerVolFracIce(iLayer)
 print*, 'nsub = ', nsub
 if(nsub>100)then
  message=trim(message)//'number of sub-steps > 100'
  err=20; return
 endif
 
 if(mLayerVolFracIce(iLayer) > 0.5_dp) pause 'ice content in top soil layer is huge...'
 
 end subroutine coupled_em

end module coupled_em_module