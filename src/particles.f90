!----------------------------------------------------------------------------
! This file is part of UCLALES.
!
! UCLALES is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! UCLALES is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.
!
! Copyright 1999-2008, Bjorn B. Stevens, Dep't Atmos and Ocean Sci, UCLA
!----------------------------------------------------------------------------
! Doxygen:
!> Lagrangian Particle Tracking Module (LPTM). 
!! Tracks massless particles driven by the interpolated velocities from the 
!! Eulerian LES grid.
!>
!! \author Bart van Stratum
!! \todo 


module modparticles
  !--------------------------------------------------------------------------
  ! module modparticles: Langrangian particle tracking, ad(o/a)pted from DALES
  !--------------------------------------------------------------------------
  implicit none
  PUBLIC :: init_particles, particles, exit_particles, initparticledump, initparticlestat, write_particle_hist, particlestat

  ! For/from namelist  
  logical            :: lpartic        = .false.        !< Switch for enabling particles
  logical            :: lpartsgs       = .false.        !< Switch for enabling particle subgrid scheme
  logical            :: lpartstat      = .false.        !< Switch for enabling particle statistics
  logical            :: lpartdump      = .false.        !< Switch for particle dump
  logical            :: lpartdumpui    = .false.        !< Switch for writing velocities to dump
  logical            :: lpartdumpth    = .false.        !< Switch for writing temperatures (liquid water / virtual potential T) to dump
  logical            :: lpartdumpmr    = .false.        !< Switch for writing moisture (total / liquid (+rain if level==3) water mixing ratio) to dump
  real               :: frqpartdump    =  3600          !< Time interval for particle dump

  character(30)      :: startfile
  integer            :: ifinput        = 1
  integer            :: np      
  integer            :: tnextdump, tnextstat
  real               :: randint   = 60.
  real               :: tnextrand = 6e6

  ! Particle structure
  type :: particle_record
    real             :: unique, tstart
    integer          :: partstep
    real             :: x, xstart, ures, ures_prev
    real             :: y, ystart, vres, vres_prev
    real             :: z, zstart, wres, wres_prev
    type (particle_record), pointer :: next,prev
  end type

  integer            :: nplisted
  type (particle_record), pointer :: head, tail

  integer            :: ipunique, ipx, ipy, ipz, ipxstart, ipystart, ipzstart, iptsart
  integer            :: ipures, ipvres, ipwres, ipures_prev, ipvres_prev, ipwres_prev, ipartstep, nrpartvar

  ! Statistics and particle dump
  integer            :: ncpartid, ncpartrec             ! Particle dump
  integer            :: ncpartstatid, ncpartstatrec     ! Particle statistics
  integer            :: nstatsamp
  
  ! Arrays for local and domain averaged values
  real, allocatable, dimension(:)     :: npartprof,    npartprofl, &
                                         uprof,        uprofl,   &
                                         vprof,        vprofl,   &
                                         wprof,        wprofl,   &
                                         u2prof,       u2profl,  &
                                         v2prof,       v2profl,  &
                                         w2prof,       w2profl,  &
                                         tkeprof,      tkeprofl, &
                                         tprof,        tprofl,   &
                                         tvprof,       tvprofl,  &
                                         rtprof,       rtprofl,  &
                                         rlprof,       rlprofl,  &
                                         ccprof,       ccprofl

  integer (KIND=selected_int_kind(10)):: idum = -12345

contains
  !
  !--------------------------------------------------------------------------
  ! Subroutine particles 
  !> Main driver of the LPTM, calls both the velocity 
  !> interpolation from the Eulerian grid and RK3 integration scheme. 
  !> called from: step.f90
  !--------------------------------------------------------------------------
  !
  subroutine particles(time,timmax) 
    use grid, only : dxi, dyi, nstep, dzi_t, dt, nzp, zm, a_km, nxp, nyp
    use defs, only : pi
    use mpi_interface, only : myid 
    implicit none
    real, intent(in)               :: time          !< time of simulation, determines the timing of particle dumps to NetCDF
    real, intent(in)               :: timmax        !< end of simulation, required to write particle dump at last timestep
    type (particle_record), pointer:: particle

    if ( np < 1 .or. nplisted < 1 ) return          ! Just to be sure..

    ! Randomize particles lowest grid level
    if (lpartsgs .and. nstep==1 .and. time > tnextrand) then
      !call randomize()
      call globalrandomize()
      tnextrand = tnextrand + randint
    end if

    particle => head
    do while( associated(particle) )
      if ( time - particle%tstart >= 0 ) then
        particle%partstep = particle%partstep + 1
        ! Interpolation of the velocity field
        particle%ures = ui3d(particle%x,particle%y,particle%z) * dxi
        particle%vres = vi3d(particle%x,particle%y,particle%z) * dyi
        particle%wres = wi3d(particle%x,particle%y,particle%z) * dzi_t(floor(particle%z))
      end if
    particle => particle%next
    end do
 
    ! Time integration
    particle => head
    do while( associated(particle) )
      if ( time - particle%tstart >= 0 ) then
        call rk3(particle)
        call checkbound(particle)
      end if
    particle => particle%next
    end do

    ! Statistics
    if (nstep==3) then
      !call checkdiv
     
      ! Particle dump
      if((time + (0.5*dt) >= tnextdump .or. time + dt >= timmax) .and. lpartdump) then
        call particledump(real(time))
        tnextdump = tnextdump + frqpartdump
      end if

      ! Particle statistics (sampling/averaging) is called from step.f90 
      ! synchronized with other profile statistics
    end if

    call partcomm

  end subroutine particles

  !
  !--------------------------------------------------------------------------
  ! Subroutine randomize 
  !> Randomizes the X,Y,Z positions of all particles in 
  !> the lowest grid level every RK3 cycle. Called from: particles()
  !--------------------------------------------------------------------------
  !
  subroutine randomize()
    use mpi_interface, only : nxg, nyg, nyprocs, nxprocs
    implicit none
  
    real      :: zmax = 1.     ! Max height in grid coordinates
    integer   :: nyloc, nxloc 
    type (particle_record), pointer:: particle

    nyloc = nyg / nyprocs
    nxloc = nxg / nxprocs
 
    particle => head
    do while(associated(particle) )
      if( particle%z <= (1. + zmax) ) then
        particle%x = (random(idum) * nyloc) + 3 
        particle%y = (random(idum) * nxloc) + 3
        particle%z = zmax * random(idum)    + 1 
      end if
      particle => particle%next
    end do 
  
  end subroutine randomize

  !
  !--------------------------------------------------------------------------
  ! Subroutine globalrandomize 
  !> Randomizes the X,Y,Z positions of all particles in 
  !> the lowest grid level every RK3 cycle. Called from: particles()
  !--------------------------------------------------------------------------
  !
  subroutine globalrandomize()
    use mpi_interface, only : nxg, nyg, nyprocs, nxprocs, mpi_integer, mpi_double_precision, mpi_sum, mpi_comm_world, ierror, wrxid, wryid, ranktable, mpi_status_size, myid
    use grid, only : deltax, deltay
    implicit none
  
    type (particle_record), pointer:: particle,ptr
    real      :: zmax = 1.                  ! Max height in grid coordinates
    integer   :: status(mpi_status_size)
    real, allocatable, dimension(:) :: buffsend,buffrecv
    integer, allocatable, dimension(:) :: recvcount,displacements
    integer   :: nglobal, nlocal=0, ii, i, k
    real      :: xsizelocal,ysizelocal,tempx,tempy,tempz

    character (len=80)   :: hname
    logical   :: dump = .true.
    real      :: randnr(3)

    ! Count number of local particles < zmax
    particle => head
    do while(associated(particle) )
      if( particle%z <= (1. + zmax) ) nlocal = nlocal + 1
      particle => particle%next
    end do 

    call mpi_allreduce(nlocal,nglobal,1,mpi_integer,mpi_sum,mpi_comm_world,ierror)

    if(nlocal > 0) then            
      ! Give them a random location and place in send buffer
      allocate(buffsend(nrpartvar * nlocal))
      ii = 0
      particle => head
      do while(associated(particle) )
        if( particle%z <= (1. + zmax) ) then
          call random_number(randnr)          ! Random seed has been called from init_particles...
          particle%x = randnr(1) * float(nxg) 
          particle%y = randnr(2) * float(nyg)
          particle%z = zmax * randnr(3) 

          call partbuffer(particle, buffsend(ii+1:ii+nrpartvar),ii,.true.)
          
          ptr => particle
          particle => particle%next
          call delete_particle(ptr)
          ii=ii+nrpartvar
        else
          particle => particle%next
        end if
      end do 
    end if

    ! Communicate number of local particles to each proc
    allocate(recvcount(nxprocs*nyprocs))
    call mpi_allgather(nlocal*nrpartvar,1,mpi_integer,recvcount,1,mpi_integer,mpi_comm_world,ierror)

    ! Create array to receive particles from other procs
    allocate(displacements(nxprocs*nyprocs))
    displacements(1) = 0
    do i = 2,nxprocs*nyprocs
      displacements(i) = displacements(i-1) + recvcount(i-1) 
    end do
    allocate(buffrecv(sum(recvcount)))

    ! Send all particles to all procs
    call mpi_allgatherv(buffsend,nlocal*nrpartvar,mpi_double_precision,buffrecv,recvcount,displacements,mpi_double_precision,mpi_comm_world,ierror)

    ! Loop through particles, check if on this proc
    xsizelocal = nxg / nxprocs
    ysizelocal = nyg / nyprocs
    ii = 0
    do i=1,nglobal   
      tempx = buffrecv(ii+2)
      tempy = buffrecv(ii+3)
      ! If on proc: add particle
      if(floor(tempx/xsizelocal) == wrxid) then
        if(floor(tempy/ysizelocal) == wryid) then
          call add_particle(particle)
          call partbuffer(particle,buffrecv(ii+1:ii+nrpartvar),ii,.false.)
          particle%x = particle%x - (floor(wrxid * xsizelocal)) + 3
          particle%y = particle%y - (floor(wryid * ysizelocal)) + 3
          particle%z = particle%z + 1
        end if
      end if
      ii = ii + nrpartvar
    end do

    ! Cleanup
    deallocate(buffsend,buffrecv)
    deallocate(recvcount,displacements)
    nlocal  = 0
    nglobal = 0

    !ii = 0
    !write(hname,'(i4.4,a3)') myid,'loc'
    !open(999,file=hname,position='append',action='write')
    !do k=1,nlocal
    !  write(999,'(4F8.2)') buffsend(ii+1),buffsend(ii+2),buffsend(ii+3),buffsend(ii+4)
    !  ii = ii + nrpartvar
    !end do
    !close(999)
    
    !ii = 0
    !write(hname,'(i4.4,a4)') myid,'glob'
    !open(998,file=hname,position='append',action='write')
    !do k=1,nglobal
    !  write(998,'(4F8.2)') buffrecv(ii+1),buffrecv(ii+2),buffrecv(ii+3),buffrecv(ii+4)
    !  ii = ii + nrpartvar
    !end do
    !close(998)

  end subroutine globalrandomize

  !
  !--------------------------------------------------------------------------
  ! Function ui3d
  !> Performs a trilinear interpolation from the Eulerian grid to the 
  !> particle position.
  !--------------------------------------------------------------------------
  !
  function ui3d(x,y,z)
    use grid, only : a_up, dzi_m, dzi_t, zt, zm
    implicit none
    real, intent(in) :: x, y, z                               !< local x,y,z position in grid coordinates
    integer          :: xbottom, ybottom, zbottom
    real             :: ui3d, deltax, deltay, deltaz, sign

    xbottom = floor(x) - 1
    ybottom = floor(y - 0.5)
    zbottom = floor(z + 0.5)
    deltax = x - 1   - xbottom
    deltay = y - 0.5 - ybottom

    ! u(1,:,:) == u(2,:,:) with zt(1) = - zt(2). By multiplying u(1,:,:) with -1, 
    ! the velocity interpolates to 0 at the surface.  
    if (zbottom==1)  then
      sign = -1
    else
      sign = 1
    end if      

    deltaz = ((zm(floor(z)) + (z - floor(z)) / dzi_t(floor(z))) - zt(zbottom)) * dzi_m(zbottom)
    ui3d          =  (1-deltaz) * (1-deltay) * (1-deltax) * sign * a_up(zbottom    , xbottom    , ybottom    ) + &    !
    &                (1-deltaz) * (1-deltay) * (  deltax) * sign * a_up(zbottom    , xbottom + 1, ybottom    ) + &    ! x+1
    &                (1-deltaz) * (  deltay) * (1-deltax) * sign * a_up(zbottom    , xbottom    , ybottom + 1) + &    ! y+1
    &                (1-deltaz) * (  deltay) * (  deltax) * sign * a_up(zbottom    , xbottom + 1, ybottom + 1) + &    ! x+1,y+1
    &                (  deltaz) * (1-deltay) * (1-deltax) *        a_up(zbottom + 1, xbottom    , ybottom    ) + &    ! z+1
    &                (  deltaz) * (1-deltay) * (  deltax) *        a_up(zbottom + 1, xbottom + 1, ybottom    ) + &    ! x+1, z+1
    &                (  deltaz) * (  deltay) * (1-deltax) *        a_up(zbottom + 1, xbottom    , ybottom + 1) + &    ! y+1, z+1
    &                (  deltaz) * (  deltay) * (  deltax) *        a_up(zbottom + 1, xbottom + 1, ybottom + 1)        ! x+1,y+1,z+1

  end function ui3d

  !
  !--------------------------------------------------------------------------
  ! Function vi3d
  !> Performs a trilinear interpolation from the Eulerian grid to the 
  !> particle position.
  !--------------------------------------------------------------------------
  !
  function vi3d(x,y,z)
    use grid, only : a_vp, dzi_m, dzi_t, zt, zm
    implicit none
    real, intent(in) :: x, y, z                               !< local x,y,z position in grid coordinates
    integer          :: xbottom, ybottom, zbottom
    real             :: vi3d, deltax, deltay, deltaz, sign

    xbottom = floor(x - 0.5)
    ybottom = floor(y) - 1
    zbottom = floor(z + 0.5)
    deltax = x - 0.5 - xbottom
    deltay = y - 1   - ybottom

    ! v(1,:,:) == v(2,:,:) with zt(1) = - zt(2). By multiplying v(1,:,:) with -1, 
    ! the velocity interpolates to 0 at the surface.  
    if (zbottom==1)  then
      sign = -1
    else
      sign = 1
    end if      

    deltaz = ((zm(floor(z)) + (z - floor(z)) / dzi_t(floor(z))) - zt(zbottom)) * dzi_m(zbottom)
    vi3d          =  (1-deltaz) * (1-deltay) * (1-deltax) * sign * a_vp(zbottom    , xbottom    , ybottom    ) + &    !
    &                (1-deltaz) * (1-deltay) * (  deltax) * sign * a_vp(zbottom    , xbottom + 1, ybottom    ) + &    ! x+1
    &                (1-deltaz) * (  deltay) * (1-deltax) * sign * a_vp(zbottom    , xbottom    , ybottom + 1) + &    ! y+1
    &                (1-deltaz) * (  deltay) * (  deltax) * sign * a_vp(zbottom    , xbottom + 1, ybottom + 1) + &    ! x+1,y+1
    &                (  deltaz) * (1-deltay) * (1-deltax) *        a_vp(zbottom + 1, xbottom    , ybottom    ) + &    ! z+1
    &                (  deltaz) * (1-deltay) * (  deltax) *        a_vp(zbottom + 1, xbottom + 1, ybottom    ) + &    ! x+1, z+1
    &                (  deltaz) * (  deltay) * (1-deltax) *        a_vp(zbottom + 1, xbottom    , ybottom + 1) + &    ! y+1, z+1
    &                (  deltaz) * (  deltay) * (  deltax) *        a_vp(zbottom + 1, xbottom + 1, ybottom + 1)        ! x+1,y+1,z+1

  end function vi3d
  
  !
  !--------------------------------------------------------------------------
  ! Function wi3d
  !> Performs a trilinear interpolation from the Eulerian grid to the 
  !> particle position.
  !--------------------------------------------------------------------------
  !
  function wi3d(x,y,z)
    use grid, only : a_wp, dzi_m, dzi_t, zt, zm
    implicit none
    real, intent(in) :: x, y, z                               !< local x,y,z position in grid coordinates
    integer          :: xbottom, ybottom, zbottom
    real             :: wi3d, deltax, deltay, deltaz

    xbottom = floor(x - 0.5)
    ybottom = floor(y - 0.5)
    zbottom = floor(z)
    deltax = x - 0.5 - xbottom
    deltay = y - 0.5 - ybottom
    deltaz = z - zbottom

    wi3d          =  (1-deltaz) * (1-deltay) * (1-deltax) *  a_wp(zbottom    , xbottom    , ybottom    ) + &    !
    &                (1-deltaz) * (1-deltay) * (  deltax) *  a_wp(zbottom    , xbottom + 1, ybottom    ) + &    ! x+1
    &                (1-deltaz) * (  deltay) * (1-deltax) *  a_wp(zbottom    , xbottom    , ybottom + 1) + &    ! y+1
    &                (1-deltaz) * (  deltay) * (  deltax) *  a_wp(zbottom    , xbottom + 1, ybottom + 1) + &    ! x+1,y+1
    &                (  deltaz) * (1-deltay) * (1-deltax) *  a_wp(zbottom + 1, xbottom    , ybottom    ) + &    ! z+1
    &                (  deltaz) * (1-deltay) * (  deltax) *  a_wp(zbottom + 1, xbottom + 1, ybottom    ) + &    ! x+1, z+1
    &                (  deltaz) * (  deltay) * (1-deltax) *  a_wp(zbottom + 1, xbottom    , ybottom + 1) + &    ! y+1, z+1
    &                (  deltaz) * (  deltay) * (  deltax) *  a_wp(zbottom + 1, xbottom + 1, ybottom + 1)        ! x+1,y+1,z+1
  
  end function wi3d

  !
  !--------------------------------------------------------------------------
  ! Function i3d
  !> trilinear interpolation from grid center to particle position
  !> Requires a 3D field as fourth argument
  !--------------------------------------------------------------------------
  !
  function i3d(x,y,z,input)
    implicit none
    real, intent(in)                    :: x, y, z                               !< local x,y,z position in grid coordinates
    real, dimension(:,:,:), intent(in)  :: input                                 !< scalar field used to interpolate from
 
    integer  :: xbottom, ybottom, zbottom
    real     :: i3d, deltax, deltay, deltaz

    xbottom = floor(x - 0.5)
    ybottom = floor(y - 0.5)
    zbottom = floor(z + 0.5)
    deltax = x - 0.5 - xbottom
    deltay = y - 0.5 - ybottom
    deltaz = z + 0.5 - zbottom
    
    i3d           =  (1-deltaz) * (1-deltay) * (1-deltax) *  input(zbottom    , xbottom    , ybottom    ) + &    !
    &                (1-deltaz) * (1-deltay) * (  deltax) *  input(zbottom    , xbottom + 1, ybottom    ) + &    ! x+1
    &                (1-deltaz) * (  deltay) * (1-deltax) *  input(zbottom    , xbottom    , ybottom + 1) + &    ! y+1
    &                (1-deltaz) * (  deltay) * (  deltax) *  input(zbottom    , xbottom + 1, ybottom + 1) + &    ! x+1,y+1
    &                (  deltaz) * (1-deltay) * (1-deltax) *  input(zbottom + 1, xbottom    , ybottom    ) + &    ! z+1
    &                (  deltaz) * (1-deltay) * (  deltax) *  input(zbottom + 1, xbottom + 1, ybottom    ) + &    ! x+1, z+1
    &                (  deltaz) * (  deltay) * (1-deltax) *  input(zbottom + 1, xbottom    , ybottom + 1) + &    ! y+1, z+1
    &                (  deltaz) * (  deltay) * (  deltax) *  input(zbottom + 1, xbottom + 1, ybottom + 1)        ! x+1,y+1,z+1

  end function i3d

  !
  !--------------------------------------------------------------------------
  ! Function i1d
  !> linear interpolation of grid center to particle position
  !> Requires a 1D profile as second argument
  !--------------------------------------------------------------------------
  !
  function i1d(z,input)
    implicit none
    real, intent(in)                    :: z                                     !< local z position in grid coordinates
    real, dimension(:), intent(in)      :: input                                 !< profile used to interpolate from
 
    integer  :: zbottom
    real     :: i1d, deltaz

    zbottom = floor(z + 0.5)
    deltaz = z + 0.5 - zbottom

    i1d    =  (1-deltaz) * input(zbottom) + deltaz * input(zbottom+1)
    i1d    =  (1-deltaz) * input(zbottom) + deltaz * input(zbottom+1)

  end function i1d

  !
  !--------------------------------------------------------------------------
  ! Subroutine rk3 
  !> Third-order Runge-Kutta scheme for spatial integration of the particles.
  !--------------------------------------------------------------------------
  !
  subroutine rk3(particle)
    use grid, only : rkalpha, rkbeta, nstep, dt, dxi, dyi, dzi_t
    implicit none
    TYPE (particle_record), POINTER:: particle

    particle%x   = particle%x + rkalpha(nstep) * particle%ures * dt + rkbeta(nstep) * particle%ures_prev * dt
    particle%y   = particle%y + rkalpha(nstep) * particle%vres * dt + rkbeta(nstep) * particle%vres_prev * dt
    particle%z   = particle%z + rkalpha(nstep) * particle%wres * dt + rkbeta(nstep) * particle%wres_prev * dt

    particle%ures_prev = particle%ures
    particle%vres_prev = particle%vres
    particle%wres_prev = particle%wres
   
   if ( nstep==3 ) then
      particle%ures_prev   = 0.
      particle%vres_prev   = 0.
      particle%wres_prev   = 0.
    end if

  end subroutine rk3

  !
  !--------------------------------------------------------------------------
  ! Subroutine partcomm 
  !> Handles the cyclic boundary conditions (through MPI) and sends
  !> particles from processor to processor
  !--------------------------------------------------------------------------
  !
  subroutine partcomm
    use mpi_interface, only : wrxid, wryid, ranktable, nxg, nyg, xcomm, ycomm, ierror, mpi_status_size, mpi_integer, mpi_double_precision, mpi_comm_world, nyprocs, nxprocs
    implicit none

    type (particle_record), pointer:: particle,ptr
    real, allocatable, dimension(:) :: buffsend, buffrecv
    integer :: status(mpi_status_size)
    integer :: ii, n
    ! Number of particles to ('to') and from ('fr') N,E,S,W
    integer :: nton,ntos,ntoe,ntow
    integer :: nfrn,nfrs,nfre,nfrw
    integer :: nyloc, nxloc 

    nton = 0
    ntos = 0
    ntoe = 0
    ntow = 0

    nyloc = nyg / nyprocs
    nxloc = nxg / nxprocs

    ! --------------------------------------------
    ! First: all north to south (j) and vice versa
    ! --------------------------------------------
    particle => head
    do while(associated(particle) )
      if( particle%y >= nyloc + 3 ) nton = nton + 1
      if( particle%y < 3          ) ntos = ntos + 1
      particle => particle%next
    end do 

    call mpi_sendrecv(nton,1,mpi_integer,ranktable(wrxid,wryid+1),4, &
                      nfrs,1,mpi_integer,ranktable(wrxid,wryid-1),4, &
                      mpi_comm_world,status,ierror) 

    call mpi_sendrecv(ntos,1,mpi_integer,ranktable(wrxid,wryid-1),5, &
                      nfrn,1,mpi_integer,ranktable(wrxid,wryid+1),5, &
                      mpi_comm_world,status,ierror) 

    !if( nton > 0 ) allocate(buffsend(nrpartvar * nton))
    !if( ntos > 0 ) allocate(buffsend(nrpartvar * ntos))
    allocate(buffsend(nrpartvar * nton))
    allocate(buffrecv(nrpartvar * nfrs))

    if( nton > 0 ) then
      particle => head
      ii = 0
      do while( associated(particle) )
        if( particle%y >= nyloc + 3 ) then
          particle%y      = particle%y      - nyloc

          call partbuffer(particle, buffsend(ii+1:ii+nrpartvar),ii,.true.)
          ptr => particle
          particle => particle%next
          call delete_particle(ptr)
          ii=ii+nrpartvar
        else
          particle => particle%next
        end if
      end do
    end if

    call mpi_sendrecv(buffsend,nrpartvar*nton,mpi_double_precision,ranktable(wrxid,wryid+1),6, &
                      buffrecv,nrpartvar*nfrs,mpi_double_precision,ranktable(wrxid,wryid-1),6, &
                      mpi_comm_world, status, ierror)

    ii = 0
    do n = 1,nfrs
      call add_particle(particle)
      call partbuffer(particle, buffrecv(ii+1:ii+nrpartvar),ii,.false.)
      ii=ii+nrpartvar
    end do

    !if( nton > 0 ) deallocate(buffsend)
    !if( nfrs > 0 ) deallocate(buffrecv)
    !if( ntos > 0 ) allocate(buffsend(nrpartvar*ntos))
    !if( nfrn > 0 ) allocate(buffrecv(nrpartvar*nfrn))
    deallocate(buffsend)
    deallocate(buffrecv)
    allocate(buffsend(nrpartvar*ntos))
    allocate(buffrecv(nrpartvar*nfrn))

    if( ntos > 0 ) then
      particle => head
      ii = 0
      do while( associated(particle) )
        if( particle%y < 3 ) then
          particle%y      = particle%y      + nyloc

          call partbuffer(particle, buffsend(ii+1:ii+nrpartvar),ii,.true.)

          ptr => particle
          particle => particle%next
          call delete_particle(ptr)
          ii=ii+nrpartvar
        else
          particle => particle%next
        end if
      end do

    end if

    call mpi_sendrecv(buffsend,nrpartvar*ntos,mpi_double_precision,ranktable(wrxid,wryid-1),7, &
                      buffrecv,nrpartvar*nfrn,mpi_double_precision,ranktable(wrxid,wryid+1),7, &
                      mpi_comm_world, status, ierror)

    ii = 0
    do n = 1,nfrn
      particle => head
      call add_particle(particle)
      call partbuffer(particle, buffrecv(ii+1:ii+nrpartvar),ii,.false.)
      ii=ii+nrpartvar
    end do

    !if( ntos > 0 ) deallocate(buffsend)
    !if( nfrn > 0 ) deallocate(buffrecv)
    deallocate(buffsend)
    deallocate(buffrecv)

    ! --------------------------------------------
    ! Second: all east to west (i) and vice versa
    ! --------------------------------------------
    particle => head
    do while(associated(particle) )
      if( particle%x >= nxloc + 3 ) ntoe = ntoe + 1
      if( particle%x < 3          ) ntow = ntow + 1
      particle => particle%next
    end do 

    call mpi_sendrecv(ntoe,1,mpi_integer,ranktable(wrxid+1,wryid),8, &
                      nfrw,1,mpi_integer,ranktable(wrxid-1,wryid),8, &
                      mpi_comm_world,status,ierror) 

    call mpi_sendrecv(ntow,1,mpi_integer,ranktable(wrxid-1,wryid),9, &
                      nfre,1,mpi_integer,ranktable(wrxid+1,wryid),9, &
                      mpi_comm_world,status,ierror) 

    !if(ntoe > 0) allocate(buffsend(nrpartvar * ntoe))
    !if(ntow > 0) allocate(buffsend(nrpartvar * ntow))
    allocate(buffsend(nrpartvar * ntoe))
    allocate(buffrecv(nrpartvar * nfrw))

    if( ntoe > 0 ) then
      particle => head
      ii = 0
      do while( associated(particle) )
        if( particle%x >= nxloc + 3 ) then
          particle%x      = particle%x      - nxloc

          call partbuffer(particle, buffsend(ii+1:ii+nrpartvar),ii,.true.)
          ptr => particle
          particle => particle%next
          call delete_particle(ptr)
          ii=ii+nrpartvar
        else
          particle => particle%next
        end if
      end do
    end if

    call mpi_sendrecv(buffsend,nrpartvar*ntoe,mpi_double_precision,ranktable(wrxid+1,wryid),10, &
                      buffrecv,nrpartvar*nfrw,mpi_double_precision,ranktable(wrxid-1,wryid),10, &
                      mpi_comm_world, status, ierror)

    ii = 0
    do n = 1,nfrw
      call add_particle(particle)
      call partbuffer(particle, buffrecv(ii+1:ii+nrpartvar),ii,.false.)
      ii=ii+nrpartvar
    end do

    !if( ntoe > 0 ) deallocate(buffsend)
    !if( nfrw > 0 ) deallocate(buffrecv)
    !if( ntow > 0 ) allocate(buffsend(nrpartvar*ntow))
    !if( nfre > 0 ) allocate(buffrecv(nrpartvar*nfre))
    deallocate(buffsend)
    deallocate(buffrecv)
    allocate(buffsend(nrpartvar*ntow))
    allocate(buffrecv(nrpartvar*nfre))

    if( ntow > 0 ) then
      particle => head
      ii = 0
      do while( associated(particle) )
        if( particle%x < 3 ) then
          particle%x      = particle%x      + nxloc

          call partbuffer(particle, buffsend(ii+1:ii+nrpartvar),ii,.true.)

          ptr => particle
          particle => particle%next
          call delete_particle(ptr)
          ii=ii+nrpartvar
        else
          particle => particle%next
        end if
      end do

    end if

    call mpi_sendrecv(buffsend,nrpartvar*ntow,mpi_double_precision,ranktable(wrxid-1,wryid),11, &
                      buffrecv,nrpartvar*nfre,mpi_double_precision,ranktable(wrxid+1,wryid),11, &
                      mpi_comm_world, status, ierror)

    ii = 0
    do n = 1,nfre
      particle => head
      call add_particle(particle)
      call partbuffer(particle, buffrecv(ii+1:ii+nrpartvar),ii,.false.)
      ii=ii+nrpartvar
    end do

    !if( ntow > 0 ) deallocate(buffsend)
    !if( nfre > 0 ) deallocate(buffrecv)
    deallocate(buffsend)
    deallocate(buffrecv)

  end subroutine partcomm

  !
  !--------------------------------------------------------------------------
  ! Subroutine partbuffer 
  !> Packs/receives particle records to/from an array, sendable over MPI 
  !--------------------------------------------------------------------------
  !
  subroutine partbuffer(particle, buffer, n, send)
    implicit none

    logical,intent(in)                :: send                               !< 
    integer,intent(in)                :: n
    real,dimension(n+1:n+nrpartvar)   :: buffer
    TYPE (particle_record), POINTER:: particle

    if (send) then
      buffer(n+ipunique)        = particle%unique
      buffer(n+ipx)             = particle%x
      buffer(n+ipy)             = particle%y
      buffer(n+ipz)             = particle%z
      buffer(n+ipures)          = particle%ures
      buffer(n+ipvres)          = particle%vres
      buffer(n+ipwres)          = particle%wres
      buffer(n+ipures_prev)     = particle%ures_prev
      buffer(n+ipvres_prev)     = particle%vres_prev
      buffer(n+ipwres_prev)     = particle%wres_prev
      buffer(n+ipxstart)        = particle%xstart
      buffer(n+ipystart)        = particle%ystart
      buffer(n+ipzstart)        = particle%zstart
      buffer(n+iptsart)         = particle%tstart
      buffer(n+ipartstep)       = particle%partstep
    else
      particle%unique           = buffer(n+ipunique)
      particle%x                = buffer(n+ipx)
      particle%y                = buffer(n+ipy)
      particle%z                = buffer(n+ipz)
      particle%ures             = buffer(n+ipures)
      particle%vres             = buffer(n+ipvres)
      particle%wres             = buffer(n+ipwres)
      particle%ures_prev        = buffer(n+ipures_prev)
      particle%vres_prev        = buffer(n+ipvres_prev)
      particle%wres_prev        = buffer(n+ipwres_prev)
      particle%xstart           = buffer(n+ipxstart)
      particle%ystart           = buffer(n+ipystart)
      particle%zstart           = buffer(n+ipzstart)
      particle%tstart           = buffer(n+iptsart)
      particle%partstep         = buffer(n+ipartstep)
    end if

  end subroutine partbuffer

  !
  !--------------------------------------------------------------------------
  ! Subroutine thermo 
  !> Calculates thermodynamic variables at particle position (thl, thv,
  !> qt, qs)  
  !--------------------------------------------------------------------------
  !
  subroutine thermo(px,py,pz,thl,thv,rt,rl)
    use thrm,         only : rslf
    use grid,         only : a_pexnr, a_rp, a_theta, a_tp, pi0, pi1,th00
    !use grid,         only : tname,nzp,dxi,dyi,dzi_t,nxp,nyp,umean,vmean, a_tp, a_rp, press, th00, a_pexnr, a_theta,pi0,pi1
    
    use defs,         only : p00,cp,R,Rm,tmelt,alvl,cpr,ep2,ep
    use thrm,         only : rslf
    implicit none
   
    real, intent(in)  :: px,py,pz
    real, intent(out) :: thl,thv,rt,rl 
    real, parameter   :: epsln = 1.e-4
    real              :: exner,ploc,tlloc,rsloc,dtx,tx,txi,tx1
    integer           :: iterate

    ! scalar interpolations and calculations
    exner   = (i1d(pz,pi0)+i1d(pz,pi1)+i3d(px,py,pz,a_pexnr)) / cp
    ploc    = p00 * exner**cpr               ! Pressure
    thl     = i3d(px,py,pz,a_tp) + th00      ! Liquid water potential T 
    tlloc   = thl * exner                    ! Liquid water T 
    rsloc   = rslf(ploc,tlloc)               ! Saturation vapor mixing ratio
    rt      = i3d(px,py,pz,a_rp)             ! Total water mixing ratio
    rl      = max(rt-rsloc,0.)               ! Liquid water mixing ratio

    if(rl > 0.) then
      dtx          = 2. * epsln
      iterate      = 1
      tx           = tlloc
      do while(dtx > epsln .and. iterate < 20)
        txi        = alvl / (cp * tx)
        tx1        = tx - (tx - tlloc * (1. + txi  * rl)) / &
                       (1. + txi * tlloc * (rl / tx + (1. + rsloc * ep) * rsloc * alvl / (Rm * tx * tx)))
        dtx        = abs(tx1 - tx)
        tx         = tx1
        iterate    = iterate + 1
        rsloc      = rslf(ploc,tx)
        rl         = max(rt-rsloc,0.)
      end do
    end if

    thv = i3d(px,py,pz,a_theta) * (1.+ep2*(rt-rl))  

  end subroutine thermo

  !
  !--------------------------------------------------------------------------
  ! Subroutine particlestat 
  !> Performs the sampling and saving of binned and slab averaged particle
  !> statistics. Output written to *.particlestat.nc  
  !--------------------------------------------------------------------------
  !
  subroutine particlestat(dowrite,time)
    use mpi_interface, only : mpi_comm_world, myid, mpi_double_precision, mpi_sum, ierror, nxprocs, nyprocs, nxg, nyg
    use modnetcdf,     only : writevar_nc, fillvalue_double
    use grid,          only : tname,dxi,dyi,dzi_t,nzp,umean,vmean
    implicit none

    logical, intent(in)     :: dowrite
    real, intent(in)        :: time
    integer                 :: k
    real                    :: thv,thl,rt,rl           ! From subroutine thermo
    type (particle_record), pointer:: particle

    ! Time averaging step
    if(.not. dowrite) then
      particle => head
      do while(associated(particle))
        k               = floor(particle%z) + 1
        npartprofl(k)   = npartprofl(k) + 1
        uprofl(k)       = uprofl(k)     + (particle%ures / dxi)
        vprofl(k)       = vprofl(k)     + (particle%vres / dyi)
        wprofl(k)       = wprofl(k)     + (particle%wres / dzi_t(floor(particle%z)))
        u2profl(k)      = u2profl(k)    + (particle%ures / dxi)**2.
        v2profl(k)      = v2profl(k)    + (particle%vres / dyi)**2.
        w2profl(k)      = w2profl(k)    + (particle%wres / dzi_t(floor(particle%z)))**2.

        call thermo(particle%x,particle%y,particle%z,thl,thv,rt,rl)

        ! scalar profiles
        tprofl(k)       = tprofl(k)     + thl
        tvprofl(k)      = tvprofl(k)    + thv
        rtprofl(k)      = rtprofl(k)    + rt
        rlprofl(k)      = rlprofl(k)    + rl
        if(rl > 0.)     ccprofl(k)      = ccprofl(k)    + 1
        particle => particle%next
      end do 

      nstatsamp = nstatsamp + 1
    end if

    ! Write to NetCDF
    if(dowrite) then
      call mpi_allreduce(npartprofl,npartprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(uprofl,uprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(vprofl,vprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(wprofl,wprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(u2profl,u2prof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(v2profl,v2prof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(w2profl,w2prof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      ! scalars
      call mpi_allreduce(tprofl,tprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(tvprofl,tvprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(rtprofl,rtprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(rlprofl,rlprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
      call mpi_allreduce(ccprofl,ccprof,nzp,mpi_double_precision,mpi_sum,mpi_comm_world,ierror)
 
      ! Divide summed values by ntime and nparticle samples and
      ! correct for Galilean transformation 
      do k = 1,nzp
        if(npartprofl(k) > 0) then 
          npartprof(k) = npartprof(k) / (nstatsamp)
          uprof(k)     = uprof(k)     / (nstatsamp * npartprof(k)) + umean
          vprof(k)     = vprof(k)     / (nstatsamp * npartprof(k)) + vmean
          wprof(k)     = wprof(k)     / (nstatsamp * npartprof(k))
          u2prof(k)    = u2prof(k)    / (nstatsamp * npartprof(k)) - (uprof(k)-umean)**2.
          v2prof(k)    = v2prof(k)    / (nstatsamp * npartprof(k)) - (vprof(k)-vmean)**2.
          w2prof(k)    = w2prof(k)    / (nstatsamp * npartprof(k)) - wprof(k)**2. 
          tkeprof(k)   = 0.5 * (u2prof(k) + v2prof(k) + w2prof(k))
          ! scalars
          tprof(k)     = tprof(k)     / (nstatsamp * npartprof(k))
          tvprof(k)    = tvprof(k)    / (nstatsamp * npartprof(k))
          rtprof(k)    = rtprof(k)    / (nstatsamp * npartprof(k))
          rlprof(k)    = rlprof(k)    / (nstatsamp * npartprof(k))
          ccprof(k)    = ccprof(k)    / (nstatsamp * npartprof(k))
        end if
      end do      

      if(myid==0) print*,'particles 1-2-3-4:',npartprof(2),npartprof(3),npartprof(4),npartprof(5)

      if(myid == 0) then
        call writevar_nc(ncpartstatid,tname,time,ncpartstatrec)
        call writevar_nc(ncpartstatid,'np',npartprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'u',uprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'v',vprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'w',wprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'u_2',u2prof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'v_2',v2prof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'w_2',w2prof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'tke',tkeprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'t',tprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'tv',tprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'rt',rtprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'rl',rlprof,ncpartstatrec)
        call writevar_nc(ncpartstatid,'cc',ccprof,ncpartstatrec)
      end if

      npartprof  = 0
      npartprofl = 0
      uprof      = 0
      uprofl     = 0
      vprof      = 0
      vprofl     = 0
      wprof      = 0
      wprofl     = 0
      u2prof     = 0
      u2profl    = 0
      v2prof     = 0
      v2profl    = 0
      w2prof     = 0
      w2profl    = 0
      tkeprof    = 0
      tkeprofl   = 0
      tprof      = 0
      tprofl     = 0
      tvprof     = 0
      tvprofl    = 0
      rtprof     = 0
      rtprofl    = 0
      rlprof     = 0
      rlprofl    = 0
      ccprof     = 0
      ccprofl    = 0
      nstatsamp  = 0
    end if

  end subroutine particlestat

  !
  !--------------------------------------------------------------------------
  ! subroutine particledump : communicates all particles to process #0 and
  !   writes it to NetCDF(4)
  !--------------------------------------------------------------------------
  !
  subroutine particledump(time)
    use mpi_interface, only : mpi_comm_world, myid, mpi_integer, mpi_double_precision, ierror, nxprocs, nyprocs, mpi_status_size, wrxid, wryid, nxg, nyg
    use grid,          only : tname, deltax, deltay, dzi_t, zm, umean, vmean
    use modnetcdf,     only : writevar_nc, fillvalue_double
    implicit none

    real, intent(in)                     :: time
    type (particle_record), pointer:: particle
    integer                              :: nlocal, ii, i, pid, partid
    integer, allocatable, dimension(:)   :: nremote
    integer                              :: status(mpi_status_size)
    integer                              :: nvar,nvl
    real, allocatable, dimension(:)      :: sendbuff, recvbuff
    real, allocatable, dimension(:,:)    :: particles_merged
    real                                 :: thl,thv,rt,rl

    nvar = 4                            ! id,x,y,z
    if(lpartdumpui)  nvar = nvar + 3    ! u,v,w
    if(lpartdumpth)  nvar = nvar + 2    ! thl,tvh
    if(lpartdumpmr)  nvar = nvar + 2    ! rt,rl

    ! Count local particles
    nlocal = 0
    particle => head
    do while( associated(particle) )
      nlocal = nlocal + 1
      particle => particle%next
    end do

    ! Communicate number of local particles to main proces (0)
    allocate(nremote(0:(nxprocs*nyprocs)-1))
    call mpi_gather(nlocal,1,mpi_integer,nremote,1,mpi_integer,0,mpi_comm_world,ierror)

    ! Create buffer
    allocate(sendbuff(nvar * nlocal))
    ii = 1
    particle => head
    do while( associated(particle) )
      if(lpartdumpth .or. lpartdumpmr) call thermo(particle%x,particle%y,particle%z,thl,thv,rt,rl)

      sendbuff(ii)   = particle%unique
      sendbuff(ii+1) = (wrxid * (nxg / nxprocs) + particle%x - 3) * deltax
      sendbuff(ii+2) = (wryid * (nyg / nyprocs) + particle%y - 3) * deltay
      sendbuff(ii+3) = zm(floor(particle%z)) + (particle%z-floor(particle%z)) / dzi_t(floor(particle%z))
      nvl = 3
      if(lpartdumpui) then
        sendbuff(ii+nvl+1) = particle%ures * deltax
        sendbuff(ii+nvl+2) = particle%vres * deltay
        sendbuff(ii+nvl+3) = particle%wres / dzi_t(floor(particle%z))
        nvl = nvl + 3
      end if
      if(lpartdumpth) then
        sendbuff(ii+nvl+1) = thl
        sendbuff(ii+nvl+2) = thv
        nvl = nvl + 2
      end if
      if(lpartdumpmr) then
        sendbuff(ii+nvl+1) = rt
        sendbuff(ii+nvl+2) = rl
      end if
      ii = ii + nvar
      particle => particle%next
    end do

    ! Dont send when main process
    if(myid .ne. 0) call mpi_send(sendbuff,nvar*nlocal,mpi_double_precision,0,myid,mpi_comm_world,ierror)

    if(myid .eq. 0) then
      allocate(particles_merged(np,nvar-1))

      ! Add local particles
      ii = 1
      do i=1,nlocal
        partid = int(sendbuff(ii))
        particles_merged(partid,1) = sendbuff(ii+1)
        particles_merged(partid,2) = sendbuff(ii+2)
        particles_merged(partid,3) = sendbuff(ii+3)
        nvl = 3
        if(lpartdumpui) then
          particles_merged(partid,nvl+1) = sendbuff(ii+nvl+1)
          particles_merged(partid,nvl+2) = sendbuff(ii+nvl+2)
          particles_merged(partid,nvl+3) = sendbuff(ii+nvl+3)
          nvl = nvl + 3
        end if
        if(lpartdumpth) then
          particles_merged(partid,nvl+1) = thl
          particles_merged(partid,nvl+2) = thv
          nvl = nvl + 2
        end if
        if(lpartdumpmr) then
          particles_merged(partid,nvl+1) = rt
          particles_merged(partid,nvl+2) = rl
        end if
        ii = ii + nvar 
      end do 

      ! Add remote particles
      do pid = 1,(nxprocs*nyprocs)-1
        allocate(recvbuff(nremote(pid)*nvar))
        call mpi_recv(recvbuff,nremote(pid)*nvar,mpi_double_precision,pid,pid,mpi_comm_world,status,ierror)   
        ii = 1
        do i=1,nremote(pid)
          partid = int(recvbuff(ii))
          particles_merged(partid,1) = recvbuff(ii+1)
          particles_merged(partid,2) = recvbuff(ii+2)
          particles_merged(partid,3) = recvbuff(ii+3)
          nvl = 3
          if(lpartdumpui) then
            particles_merged(partid,nvl+1) = recvbuff(ii+nvl+1)
            particles_merged(partid,nvl+2) = recvbuff(ii+nvl+2)
            particles_merged(partid,nvl+3) = recvbuff(ii+nvl+3)
            nvl = nvl + 3
          end if
          if(lpartdumpth) then
            particles_merged(partid,nvl+1) = recvbuff(ii+nvl+1)
            particles_merged(partid,nvl+2) = recvbuff(ii+nvl+2)
            nvl = nvl + 2
          end if
          if(lpartdumpmr) then
            particles_merged(partid,nvl+1) = recvbuff(ii+nvl+1)
            particles_merged(partid,nvl+2) = recvbuff(ii+nvl+2)
          end if
          ii = ii + nvar 
        end do 
        deallocate(recvbuff)
      end do

      ! Correct for Galilean transformation
      if(lpartdumpui) then
        particles_merged(:,4) = particles_merged(:,4) + umean
        particles_merged(:,5) = particles_merged(:,5) + vmean
      end if

      ! Write to NetCDF
      call writevar_nc(ncpartid,tname,time,ncpartrec)
      call writevar_nc(ncpartid,'x',particles_merged(:,1),ncpartrec)
      call writevar_nc(ncpartid,'y',particles_merged(:,2),ncpartrec)
      call writevar_nc(ncpartid,'z',particles_merged(:,3),ncpartrec)
      nvl = 3
      if(lpartdumpui) then
        call writevar_nc(ncpartid,'u',particles_merged(:,nvl+1),ncpartrec)
        call writevar_nc(ncpartid,'v',particles_merged(:,nvl+2),ncpartrec)
        call writevar_nc(ncpartid,'w',particles_merged(:,nvl+3),ncpartrec)
        nvl = nvl + 3
      end if
      if(lpartdumpth) then
        call writevar_nc(ncpartid,'t', particles_merged(:,nvl+1),ncpartrec)
        call writevar_nc(ncpartid,'tv',particles_merged(:,nvl+2),ncpartrec)
        nvl = nvl + 2
      end if
      if(lpartdumpmr) then
        call writevar_nc(ncpartid,'rt',particles_merged(:,nvl+1),ncpartrec)
        call writevar_nc(ncpartid,'rl',particles_merged(:,nvl+2),ncpartrec)
      end if
    end if
    
    if(myid==0) deallocate(particles_merged)
    deallocate(nremote, sendbuff)
 
  end subroutine particledump

  !
  !--------------------------------------------------------------------------
  ! Quick and dirty local divergence check
  !--------------------------------------------------------------------------
  !
  subroutine checkdiv
  use grid, only : dxi, dyi, dzi_t, a_up, a_vp, a_wp, nxp, nyp, nzp, dn0
  use mpi_interface, only : myid
  implicit none
  integer :: i,j,k
  real :: dudx,dvdy,dwdz,div
  real :: divmax,divtot
  real :: dnp,dnm

  div = 0.
  divmax = 0.
  divtot = 0.

  do j=3,nyp-2
    do i=3,nxp-2
      do k=2,nzp-2
        dnp  = 0.5 * (dn0(k) + dn0(k+1))
        dnm  = 0.5 * (dn0(k) + dn0(k-1))
        dudx = (a_up(k,i,j) - a_up(k,i-1,j)) * dxi * dn0(k)
        dvdy = (a_vp(k,i,j) - a_vp(k,i,j-1)) * dyi * dn0(k)
        dwdz = ((a_wp(k,i,j) * dnp) - (a_wp(k-1,i,j) * dnm)) * dzi_t(k)
        div  = dudx + dvdy + dwdz
        divtot = divtot + div
        if(abs(div) > divmax) divmax = abs(div)
      end do
    end do
  end do
 
  !if(myid==0) print*,'   divergence; max=',divmax, ', total=',divtot 

  end subroutine checkdiv

  !
  !--------------------------------------------------------------------------
  ! subroutine checkbound : bounces particles of surface and model top
  !--------------------------------------------------------------------------
  !
  subroutine checkbound(particle)
    use grid, only : nxp, nyp, nzp, zm
    implicit none

    type (particle_record), pointer:: particle

    ! Reflect particles of surface and model top
    if (particle%z >= nzp-1) then
      particle%z = nzp-1-0.0001
      particle%wres = -abs(particle%wres)
    elseif (particle%z < 1.01) then
      particle%z = abs(particle%z-1.01)+1.01
      particle%wres =  abs(particle%wres)
    end if

  end subroutine checkbound

  !
  !--------------------------------------------------------------------------
  ! function xi & random : creates component of white Gaussian noise (random
  !   number from Gaussian distr.) using the Box-Müller algorithm   
  !--------------------------------------------------------------------------
  !
  function xi(idum)
    implicit none
    integer (KIND=selected_int_kind(10)):: idum
    integer (KIND=selected_int_kind(10)):: iset
    real :: xi, fac, gset, rsq, v1, v2
    save iset, gset
    data iset /0/
    
    rsq   = 0.
    v1    = 0.
    v2    = 0.

    if (iset == 0) then
      do while (rsq >= 1 .or. rsq == 0)
        v1        = 2. * random(idum)-1.
        v2        = 2. * random(idum)-1.
        rsq       = v1 * v1 + v2 * v2
      end do
      fac         = sqrt(-2. * log(rsq) / rsq)
      gset        = v1 * fac
      xi          = v2 * fac
      iset        = 1
    else
      xi          = gset
      iset        = 0
    end if
    return
  end function xi

  function random(idum)
    implicit none
    integer, parameter :: ntab = 32
    integer (KIND=selected_int_kind(10)):: idum 
    integer (KIND=selected_int_kind(10)):: ia, im, iq, ir, iv(ntab), iy, ndiv, threshold=1
    real :: random, am, eps1, rnmx

    integer :: j, k
    save iv, iy

    ia     = 16807
    im     = 2147483647
    am     = 1. / real(im)
    iq     = 127773
    ir     = 2836
    ndiv   = 1 +  (im-1)/real(ntab)
    eps1   = 1.2E-7
    rnmx   = 1. - eps1

    data iv /ntab*0/ , iy /0/

    if (idum <= 0 .or. iy == 0 ) then
      idum    = max(idum,threshold)
      do j    = ntab + 8, 1, -1
        k     = idum / real(iq)
        idum  = ia * (idum - k * iq) - ir * k
        if (idum < 0) idum = idum + im
        if (j <= ntab ) iv(j) = idum
      end do
      iy = iv(1)
    end if
    
    k      = idum / real(iq)
    idum   = ia * (idum - k * iq) - ir * k
    if (idum <= 0) idum = idum + im
    j      = 1 + iy / real(ndiv)
    iy     = iv(j)
    iv(j)  = idum
    random = min(am*iy,rnmx)
    return
  end function random


  !--------------------------------------------------------------------------
  !
  ! BELOW: ONLY INIT / EXIT PARTICLES
  !
  !--------------------------------------------------------------------------
  !
  ! subroutine init_particles: initialize particles, reading initial position, 
  ! etc. Called from subroutine initialize (init.f90)
  !--------------------------------------------------------------------------
  !
  subroutine init_particles(hot,hfilin)
    use mpi_interface, only : wrxid, wryid, nxg, nyg, myid, nxprocs, nyprocs, appl_abort
    use grid, only : zm, deltax, deltay, zt,dzi_t, nzp, nxp, nyp
    use grid, only : a_up, a_vp, a_wp

    logical, intent(in) :: hot
    character (len=80), intent(in), optional :: hfilin
    integer  :: k, n, kmax, io
    logical  :: exans
    real     :: tstart, xstart, ystart, zstart, ysizelocal, xsizelocal, firststart
    real     :: pu,pts,px,py,pz,pxs,pys,pzs,pur,pvr,pwr,purp,pvrp,pwrp
    integer  :: pstp,idot
    type (particle_record), pointer:: particle
    character (len=80) :: hname,prefix,suffix

    xsizelocal = (nxg / nxprocs) * deltax
    ysizelocal = (nyg / nyprocs) * deltay
    kmax = size(zm)

    firststart = 1e9
    call init_random_seed()

    ! clear pointers to head and tail
    nullify(head)
    nullify(tail)
    nplisted = 0

    if(hot) then
    ! ------------------------------------------------------
    ! Warm start -> load restart file

      write(hname,'(i4.4,a1,i4.4)') wrxid,'_',wryid
      idot = scan(hfilin,'.',.false.)
      prefix = hfilin(:idot-1)
      suffix = hfilin(idot+1:)
      hname = trim(hname)//'.'//trim(prefix)//'.particles.'//trim(suffix)
      inquire(file=trim(hname),exist=exans)
      if (.not.exans) then
         print *,'ABORTING: History file', trim(hname),' not found'
         call appl_abort(0)
      end if
      open (666,file=hname,status='old',form='unformatted')
      read (666,iostat=io) np,tnextdump
      do
        read (666,iostat=io) pu,pts,pstp,px,pxs,pur,purp,py,pys,pvr,pvrp,pz,pzs,pwr,pwrp
        if(io .ne. 0) exit
        call add_particle(particle)
        particle%unique         = pu
        particle%x              = px
        particle%y              = py
        particle%z              = pz
        particle%xstart         = pxs
        particle%ystart         = pys
        particle%zstart         = pzs
        particle%tstart         = pts
        particle%ures           = pur
        particle%vres           = pvr
        particle%wres           = pwr
        particle%ures_prev      = purp
        particle%vres_prev      = pvrp
        particle%wres_prev      = pwrp
        particle%partstep       = pstp
        if(pts < firststart) firststart = pts
      end do
      close(666)

      tnextrand = tnextdump

    else                 
    ! ------------------------------------------------------
    ! Cold start -> load particle startpositions from txt

      np = 0
      startfile = 'partstartpos'
      open(ifinput,file=startfile,status='old',position='rewind',action='read')
      read(ifinput,'(I10.1)') np
      if ( np < 1 ) return
      ! read particles from partstartpos, create linked list
      do n = 1, np
        read(ifinput,*) tstart, xstart, ystart, zstart
        if(floor(xstart / xsizelocal) == wrxid) then
          if(floor(ystart / ysizelocal) == wryid) then
            call add_particle(particle)
            particle%unique         = n !+ myid/1000.0
            particle%x              = (xstart - (float(wrxid) * xsizelocal)) / deltax + 3.  ! +3 here for ghost cells.
            particle%y              = (ystart - (float(wryid) * ysizelocal)) / deltay + 3.  ! +3 here for ghost cells.
            do k=kmax,1,1
              if ( zm(k)<zstart ) exit
            end do
            particle%z              = k + (zstart-zm(k))*dzi_t(k)
            particle%xstart         = xstart
            particle%ystart         = ystart
            particle%zstart         = zstart
            particle%tstart         = tstart
            particle%ures           = 0.
            particle%vres           = 0.
            particle%wres           = 0.
            particle%ures_prev      = 0.
            particle%vres_prev      = 0.
            particle%wres_prev      = 0.
            particle%partstep       = 0

            if(tstart < firststart) firststart = tstart

          end if
        end if
      end do
      ! Set first dump times
      tnextdump = firststart
      tnextrand = firststart
      tnextstat = 0
      nstatsamp = 0
    end if

    ipunique        = 1
    ipx             = 2
    ipy             = 3
    ipz             = 4
    ipxstart        = 5
    ipystart        = 6
    ipzstart        = 7
    iptsart         = 8
    ipures          = 9
    ipvres          = 10
    ipwres          = 11
    ipures_prev     = 12
    ipvres_prev     = 13
    ipwres_prev     = 14
    ipartstep       = 15
    nrpartvar       = ipartstep
 
    if(lpartstat) then
      allocate(npartprof(nzp),npartprofl(nzp),     &
                   uprof(nzp),    uprofl(nzp),     &
                   vprof(nzp),    vprofl(nzp),     &
                   wprof(nzp),    wprofl(nzp),     &
                   u2prof(nzp),   u2profl(nzp),    &
                   v2prof(nzp),   v2profl(nzp),    &
                   w2prof(nzp),   w2profl(nzp),    &
                   tkeprof(nzp),  tkeprofl(nzp),   &
                   tprof(nzp),    tprofl(nzp),     &
                   tvprof(nzp),   tvprofl(nzp),    &
                   rtprof(nzp),   rtprofl(nzp),    &
                   rlprof(nzp),   rlprofl(nzp),    &
                   ccprof(nzp),   ccprofl(nzp))
    end if  

 
    close(ifinput)

  end subroutine init_particles
  
  !
  !--------------------------------------------------------------------------
  ! subroutine exit_particles
  !--------------------------------------------------------------------------
  !
  subroutine exit_particles
    use mpi_interface, only : myid
    implicit none

    do while( associated(tail) )
      call delete_particle(tail)
    end do

    if(myid == 0) print "(//' ',49('-')/,' ',/,'  Lagrangian particles removed.')"
  end subroutine exit_particles

  !
  !--------------------------------------------------------------------------
  ! subroutine write_hist; writes history files for warm restart particles
  !   called from: init.f90, step.f90
  !--------------------------------------------------------------------------
  !
  subroutine write_particle_hist(htype, time)
    use mpi_interface, only : myid,wrxid,wryid
    use grid,          only : filprf
    implicit none
    integer, intent (in) :: htype
    real, intent (in)    :: time
    character (len=80)   :: hname
    type (particle_record), pointer:: particle
    integer              :: iblank

    write(hname,'(i4.4,a1,i4.4)') wrxid,'_',wryid
    hname = trim(hname)//'.'//trim(filprf)//'.particles'

    select case(htype)
    case default
       hname = trim(hname)//'.iflg'
    case(0)
       hname = trim(hname)//'.R'
    case(1) 
       hname = trim(hname)//'.rst'
    case(2) 
       iblank=index(hname,' ')
       write (hname(iblank:iblank+7),'(a1,i6.6,a1)') '.', int(time), 's'
    end select

    open(666,file=trim(hname), form='unformatted')
    write(666) np,tnextdump
    particle => head
    do while(associated(particle))
      write(666) particle%unique, particle%tstart, particle%partstep, & 
        particle%x, particle%xstart, particle%ures, particle%ures_prev, & 
        particle%y, particle%ystart, particle%vres, particle%vres_prev, & 
        particle%z, particle%zstart, particle%wres, particle%wres_prev
      particle => particle%next
    end do 

    close(666)

  end subroutine write_particle_hist

  !
  !--------------------------------------------------------------------------
  ! subroutine initparticledump : creates NetCDF file for particle dump. 
  !   Called from: init.f90
  !--------------------------------------------------------------------------
  !
  subroutine initparticledump(time)
    use modnetcdf,       only : open_nc, addvar_nc
    use grid,            only : nzp, tname, tlongname, tunit, filprf
    use mpi_interface,   only : myid
    use grid,            only : tname, tlongname, tunit
    implicit none

    real, intent(in)                  :: time
    character (40), dimension(2)      :: dimname, dimlongname, dimunit
    real, allocatable, dimension(:,:) :: dimvalues
    integer, dimension(2)             :: dimsize
    integer                           :: k
    integer, parameter                :: precis = 0

    allocate(dimvalues(np,2))

    dimvalues      = 0
    do k=1,np
      dimvalues(k,1) = k
    end do

    dimname(1)     = 'particles'
    dimlongname(1) = 'ID of particle'
    dimunit(1)     = '-'    
    dimsize(1)     = np
    dimname(2)     = tname
    dimlongname(2) = tlongname
    dimunit(2)     = tunit
    dimsize(2)     = 0
 
    if(myid == 0) then
      call open_nc(trim(filprf)//'.particles.nc', ncpartid, ncpartrec, time, .false.)
      call addvar_nc(ncpartid,'x','x-position of particle','m',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      call addvar_nc(ncpartid,'y','y-position of particle','m',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      call addvar_nc(ncpartid,'z','z-position of particle','m',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      if(lpartdumpui) then
        call addvar_nc(ncpartid,'u','resolved u-velocity of particle','m/s',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
        call addvar_nc(ncpartid,'v','resolved v-velocity of particle','m/s',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
        call addvar_nc(ncpartid,'w','resolved w-velocity of particle','m/s',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      end if
      if(lpartdumpth) then
        call addvar_nc(ncpartid,'t','liquid water potential temperature','K',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
        call addvar_nc(ncpartid,'tv','virtual potential temperature','K',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      end if
      if(lpartdumpmr) then
        call addvar_nc(ncpartid,'rt','total water mixing ratio','K',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
        call addvar_nc(ncpartid,'rl','liquid water mixing ratio','K',dimname,dimlongname,dimunit,dimsize,dimvalues,precis)
      end if
    end if 
 
  end subroutine initparticledump

  !
  !--------------------------------------------------------------------------
  ! subroutine initparticlestat : creates NetCDF file for particle statistics. 
  !   Called from: init.f90
  !--------------------------------------------------------------------------
  !
  subroutine initparticlestat(time)
    use modnetcdf,       only : open_nc, addvar_nc
    use grid,            only : nzp, tname, tlongname, tunit, filprf
    use mpi_interface,   only : myid
    use grid,            only : tname, tlongname, tunit, zname, zlongname, zunit, zt
    implicit none

    real, intent(in)                  :: time
    character (40), dimension(2)      :: dimname, dimlongname, dimunit
    real, allocatable, dimension(:,:) :: dimvalues
    integer, dimension(2)             :: dimsize

    allocate(dimvalues(nzp,2))
    dimvalues = 0
    dimvalues(1:nzp,1)  = zt(1:nzp)

    dimname(1)     = zname
    dimlongname(1) = zlongname
    dimunit(1)     = zunit
    dimsize(1)     = nzp-2
    dimname(2)     = tname
    dimlongname(2) = tlongname
    dimunit(2)     = tunit
    dimsize(2)     = 0
 
    if(myid == 0) then
      call open_nc(trim(filprf)//'.particlestat.nc', ncpartstatid, ncpartstatrec, time, .false.)
      call addvar_nc(ncpartstatid,'np','Number of particles','-',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'u','resolved u-velocity of particle','m s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'v','resolved v-velocity of particle','m s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'w','resolved w-velocity of particle','m s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'u_2','resolved u-velocity variance of particle','m2 s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'v_2','resolved v-velocity variance of particle','m2 s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'w_2','resolved w-velocity variance of particle','m2 s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'tke','resolved TKE of particle','m s-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'t','liquid water potential temperature','K',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'tv','virtual potential temperature','K',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'rt','total water mixing ratio','kg kg-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'rl','liquid water mixing ratio','kg kg-1',dimname,dimlongname,dimunit,dimsize,dimvalues)
      call addvar_nc(ncpartstatid,'cc','cloud fraction','-',dimname,dimlongname,dimunit,dimsize,dimvalues)
    end if 
 
  end subroutine initparticlestat

  !
  !--------------------------------------------------------------------------
  ! subroutine exitparticledump
  !   Called from: step.f90
  !--------------------------------------------------------------------------
  !
  subroutine exitparticledump
    use modnetcdf,       only : close_nc
    implicit none
    call close_nc(ncpartid)     
  end subroutine exitparticledump

  !
  !--------------------------------------------------------------------------
  ! subroutine exitparticlestat
  !   Called from: step.f90
  !--------------------------------------------------------------------------
  !
  subroutine exitparticlestat
    use modnetcdf,       only : close_nc
    implicit none
    call close_nc(ncpartstatid)     
  end subroutine exitparticlestat

  !
  !--------------------------------------------------------------------------
  ! subroutine init_particles
  !--------------------------------------------------------------------------
  !
  subroutine add_particle(ptr)
    implicit none                                         
                                   
    TYPE (particle_record), POINTER:: ptr
    TYPE (particle_record), POINTER:: new_p

    if( .not. associated(head) ) then 
      allocate(head)
      tail => head
      nullify(head%prev)
    else
      allocate(tail%next)
      new_p => tail%next
      new_p%prev => tail
      tail => new_p
    end if

    nplisted = nplisted + 1
    nullify(tail%next)
    ptr => tail

  end SUBROUTINE add_particle

  !
  !--------------------------------------------------------------------------
  ! subroutine delete_particle
  !--------------------------------------------------------------------------
  !
  subroutine delete_particle(ptr)
    implicit none
    TYPE (particle_record), POINTER:: ptr
    TYPE (particle_record), POINTER:: next_p,prev_p,cur_p

    cur_p => ptr
    if( .not. associated(cur_p) ) then         !error in calling ptr
      write(6,*) 'WARNING: cannot delete empty pointer'
      return
    end if

    if( .not. associated(head) ) then         !empty list
      write(6,*) 'WARNING: cannot delete elements in an empty list'
    else
      if( .not. associated(cur_p%next) ) then   ! last in list
        if( .not. associated(cur_p%prev) ) then ! last element
          nullify(head)
          nullify(tail)
        else
          tail => cur_p%prev
          nullify(tail%next)
        end if
      else
        if( .not. associated(cur_p%prev) ) then ! first in list
          if( .not. associated(cur_p%next) ) then !last element
            nullify(head)
            nullify(tail)
          else
            head => cur_p%next
            nullify(head%prev)
          end if
        else
          next_p => cur_p%next
          prev_p => cur_p%prev
          next_p%prev => prev_p
          prev_p%next => next_p
        end if
      end if

      nplisted = nplisted - 1
      deallocate(cur_p)
    end if

  end subroutine delete_particle

  subroutine init_random_seed()
    use mpi_interface,   only : myid

    integer :: i, n, clock
    integer, dimension(:), allocatable :: seed
  
    call random_seed(size = n)
    allocate(seed(n))
    call system_clock(count=clock)
    seed = clock + 37 * (/ (i - 1, i = 1, n) /)
    call random_seed(put = seed)
  
    deallocate(seed)
  end subroutine init_random_seed

end module modparticles
