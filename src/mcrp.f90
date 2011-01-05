&!----------------------------------------------------------------------------
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
! Copyright 1999-2007, Bjorn B. Stevens, Dep't Atmos and Ocean Sci, UCLA
!----------------------------------------------------------------------------
!
module mcrp

  use defs, only : alvl, rowt, pi, Rm, cp
  use grid, only : dt, dxi, dyi ,dzi_t, nxp, nyp, nzp, a_pexnr, a_rp, a_tp, th00, CCN,    &
       dn0, pi0,pi1, a_rt, a_tt,a_up, a_rpp, a_rpt, a_npp, a_npt, vapor, liquid,       &
       a_theta, a_scr1, a_scr2, a_scr7, precip, a_pexnr  ! Louise: added a_pexnr,pi1,a_scr7, a_up - In newer version 3.1 a_scr1 is changed to a_pexnr and a_scr2 to satvpr
  use thrm, only : thermo, fll_tkrs
  use stat, only : sflg, updtst
  use util, only : get_avg3, azero
  implicit none

  logical, parameter :: droplet_sedim = .False., khairoutdinov = .False., turbulence = .False.
  ! 
  ! drop sizes definition is based on vanZanten (2005)
  ! cloud droplets' diameter: 2-50 e-6 m
  ! drizzle drops' diameter: 50-1000 e-6 m
  !
  real, parameter :: eps0 = 1e-20       ! small number
  real, parameter :: eps1 = 1e-9        ! small number
  real, parameter :: rho_0 = 1.21       ! air density at surface

  real, parameter :: D_min = 2.e-6      ! minimum diameter of cloud droplets
  real, parameter :: D_bnd = 80.e-6     ! precip/cloud diameter boundary
  real, parameter :: D_max = 1.e-3      ! maximum diameter of prcp drops

  real, parameter :: X_min = (D_min**3)*rowt*pi/6. ! min cld mass
  real, parameter :: X_bnd = (D_bnd**3)*rowt*pi/6. ! precip/cld bound mass
  real, parameter :: X_max = (D_max**3)*rowt*pi/6. ! max prcp mass

  real, parameter :: prw = pi * rowt / 6.

contains

  !
  ! ---------------------------------------------------------------------
  ! MICRO: sets up call to microphysics
  !

  !Louise: changed a_scr1/a_scr2 to a_pexnr/satvpr in this subroutine

  subroutine micro(level)

    integer, intent (in) :: level

    call fll_tkrs(nzp,nxp,nyp,a_theta,a_pexnr,pi0,pi1,dn0,th00,a_scr1,rs=a_scr2)

    select case (level) 
    case(2)
       if (droplet_sedim) call sedim_cd(nzp,nxp,nyp,dt,a_theta,a_scr1,      &
            liquid,precip,a_rt,a_tt)     
    case(3)
       call mcrph(nzp,nxp,nyp,dn0,a_theta,a_scr1,vapor,a_scr2,liquid,a_rpp, &
            a_npp,precip,a_rt,a_tt,a_rpt,a_npt,a_up,a_scr7)
    end select

  end subroutine micro
  !
  ! ---------------------------------------------------------------------
  ! MCRPH: calls microphysical parameterization 
  !
  ! Louise: in newer version variable tk should be changed to exner and subroutines wtr_dff_SB and sedim_rd
  ! should be replaced with those present in mrcp.f90 from UCLA LES 3.1

  subroutine mcrph(n1,n2,n3,dn0,th,tk,rv,rs,rc,rp,np,rrate,         &
       rtt,tlt,rpt,npt,up,dissip)

    integer, intent (in) :: n1,n2,n3
    real, dimension(n1,n2,n3), intent (in)    :: th, tk, rv, rs, up, dissip
    real, dimension(n1)      , intent (in)    :: dn0
    real, dimension(n1,n2,n3), intent (inout) :: rc, rtt, tlt, rpt, npt, np, rp
    real, intent (out)                        :: rrate(n1,n2,n3)

    integer :: i, j, k

    !
    ! Microphysics following Seifert Beheng (2001, 2005)       
    ! note that the order below is important as the rc array is 
    ! redefined in cld_dgn below and is assumed to be cloud water 
    ! after that and total condensate priort to that
    !
    
    do j=3,n3-2
       do i=3,n2-2 
          do k=1,n1
             rp(k,i,j) = max(0., rp(k,i,j))
             np(k,i,j) = max(min(rp(k,i,j)/X_bnd,np(k,i,j)),rp(k,i,j)/X_max)
          end do
       end do
    end do 

    !call wtr_dff_SB(n1,n2,n3,dn0,rp,np,rc,rs,rv,exner,th,rpt,npt)
    call wtr_dff_SB(n1,n2,n3,dn0,rp,np,rc,rs,rv,tk,rpt,npt)

    call auto_SB(n1,n2,n3,dn0,rc,rp,rpt,npt,a_scr7,a_up)
    
    call accr_SB(n1,n2,n3,dn0,rc,rp,np,rpt,npt,a_scr7)
   
    call sedim_rd(n1,n2,n3,dt,dn0,rp,np,tk,th,rrate,rtt,tlt,rpt,npt)

   !call sedim_rd(n1,n2,n3,dt,dn0,rp,np,exner,rrate,rtt,tlt,rpt,npt)
    
    if (droplet_sedim) call sedim_cd(n1,n2,n3,dt,th,tk,rc,rrate,rtt,tlt)
   !call sedim_cd(n1,n2,n3,dt,exner,rc,rrate,rtt,tlt)

  end subroutine mcrph
  ! 
  ! ---------------------------------------------------------------------
  ! WTR_DFF_SB: calculates the evolution of the both number- and
  ! mass mixing ratio large drops due to evaporation in the absence of 
  ! cloud water.  
  ! 
  ! Louise: subroutine should be replaced with one from LES version 3.1


  subroutine wtr_dff_SB(n1,n2,n3,dn0,rp,np,rl,rs,rv,tk,rpt,npt)

    integer, intent (in) :: n1,n2,n3
    real, intent (in)    :: tk(n1,n2,n3), np(n1,n2,n3), rp(n1,n2,n3),        &
         rs(n1,n2,n3),rv(n1,n2,n3), dn0(n1)
    real, intent (inout) :: rpt(n1,n2,n3), npt(n1,n2,n3), rl(n1,n2,n3)

    real, parameter    :: Kt = 2.5e-2    ! conductivity of heat [J/(sKm)]
    real, parameter    :: Dv = 3.e-5     ! diffusivity of water vapor [m2/s]

    integer             :: i, j, k
    real                :: Xp, Dp, G, S, cerpt, cenpt, xnpts
    real, dimension(n1) :: v1

    if(sflg) then
       xnpts = 1./((n3-4)*(n2-4))
       do k=1,n1
          v1(k) = 0.
       end do
    end if

    do j=3,n3-2
       do i=3,n2-2 
          do k=2,n1
             if (rp(k,i,j) > rl(k,i,j)) then
                Xp = rp(k,i,j)/ (np(k,i,j)+eps0)
                Xp = MIN(MAX(Xp,X_bnd),X_max)
                Dp = ( Xp / prw )**(1./3.)

                G = 1. / (1. / (dn0(k)*rs(k,i,j)*Dv) + &
                     alvl*(alvl/(Rm*tk(k,i,j))-1.) / (Kt*tk(k,i,j)))
                S = rv(k,i,j)/rs(k,i,j) - 1.

                if (S < 0) then
                   cerpt = 2. * pi * Dp * G * S * np(k,i,j)
                   cenpt = cerpt * np(k,i,j) / rp(k,i,j)
                   rpt(k,i,j)=rpt(k,i,j) + cerpt
                   npt(k,i,j)=npt(k,i,j) + cenpt
                   if (sflg) v1(k) = v1(k) + cerpt * xnpts
                end if
             end if
             rl(k,i,j) = max(0.,rl(k,i,j) - rp(k,i,j))
          end do
       end do
    end do

    if (sflg) call updtst(n1,'prc',2,v1,1)

  end subroutine wtr_dff_SB 
 
  !
  ! ---------------------------------------------------------------------
  ! AUTO_SB:  calculates the evolution of mass- and number mxg-ratio for 
  ! drizzle drops due to autoconversion. The autoconversion rate assumes
  ! f(x)=A*x**(nu_c)*exp(-Bx), an exponential in drop MASS x. It can 
  ! be reformulated for f(x)=A*x**(nu_c)*exp(-Bx**(mu)), where formu=1/3
  ! one would get a gamma dist in drop diam -> faster rain formation.
  !
  subroutine auto_SB(n1,n2,n3,dn0,rc,rp,rpt,npt,diss,up)

    integer, intent (in) :: n1,n2,n3
    real, intent (in)    :: dn0(n1), rc(n1,n2,n3), rp(n1,n2,n3), diss(n1,n2,n3), up(n1,n2,n3)
    real, intent (inout) :: rpt(n1,n2,n3), npt(n1,n2,n3)

    real, parameter :: nu_c  = 4.           ! width parameter of cloud DSD 
    real, parameter :: kc_0  = 9.44e+9      ! Long-Kernel
    real, parameter :: k_1  = 6.e+2        ! Parameter for phi function
    real, parameter :: k_2  = 0.68         ! Parameter for phi function

    real, parameter :: Cau = 4.1e-15 ! autoconv. coefficient in KK param.
    real, parameter :: Eau = 5.67    ! autoconv. exponent in KK param.
    real, parameter :: mmt = 1.e+6   ! transformation from m to \mu m

    real, parameter :: kc_a1 = 0.00489
    real, parameter :: kc_a2 = -0.00042
    real, parameter :: kc_a3 = -0.01400
    real, parameter :: kc_b1 = 11.45
    real, parameter :: kc_b2 = 9.68
    real, parameter :: kc_b3 = 0.62
    real, parameter :: kc_c1 = 4.82
    real, parameter :: kc_c2 = 4.80
    real, parameter :: kc_c3 = 0.76
    real, parameter :: kc_bet = 0.00174
    real, parameter :: csx = 0.23
    real, parameter :: ce = 0.93
   
    integer :: i, j, k
    real    :: k_au, Xc, Dc, au, tau, phi, kc_alf, kc_rad, kc_sig, k_c, Re, epsilon, l   
    real, dimension(n1) :: Resum, Recnt       

    !
    ! Louise : calculate the effect of turbulence on the autoconversion/
    ! accretion rate using equation (6) in Seifert et al. (2009) 
    ! 
    
    if (turbulence) then
       kc_alf = ( kc_a1 + kc_a2 * nu_c )/ ( 1. + kc_a3 * nu_c )
       kc_rad = ( kc_b1 + kc_b2 * nu_c )/ ( 1. + kc_b3 * nu_c )
       kc_sig = ( kc_c1 + kc_c2 * nu_c )/ ( 1. + kc_c3 * nu_c )
       call azero(n1,Recnt,Resum)
    end if   

    do j=3,n3-2
       do i=3,n2-2 
          do k=2,n1-1
             Xc = rc(k,i,j)/(CCN+eps0)
             if (Xc > 0.) then 
                Xc = MIN(MAX(Xc,X_min),X_bnd) 
                k_c = kc_0

                if (turbulence) then
                   Dc = ( Xc / prw )**(1./3.)  ! mass mean diameter cloud droplets in m              
                   ! 
                   ! Calculate the mixing length, dissipation rate and Taylor-Reynolds number
                   !
                   l = csx*((1/dxi)*(1/dyi)*(1/dzi_t(k)))**(1./3.)
                   epsilon = min(diss(k,i,j),0.06)
                   Re = (6./11.)*((l/ce)**(2./3))*((15./(1.5e-5))**0.5)*(epsilon**(1./6) )                   
                   !
                   ! Dissipation needs to be converted to cm^2/s^3 which explains the factor
                   ! 1.e4 with which diss(k,i,j) is multiplied
                   !
                   k_c = k_c * (1. + epsilon *1.e4* (Re*1.e-3)**(0.25) & 
                         * (kc_bet + kc_alf * exp( -1.* ((((Dc/2.)*1.e+6-kc_rad)/kc_sig)**2) )))  
                   !print *,'enhancement factor = ', k_c/(9.44e+9)
                   !
                   ! Calculate conditional average of Re i.e., conditioned on cloud/rain water
                   !
                   Resum(k) = Resum(k)+ Re
                   Recnt(k) = Recnt(k)+ 1
                end if   

                k_au  = k_c / (20.*X_bnd) * (nu_c+2.)*(nu_c+4.)/(nu_c+1.)**2
                au = k_au * dn0(k) * rc(k,i,j)**2 * Xc**2
                !
                ! small threshold that should not influence the result
                !
                if (rc(k,i,j) > 1.e-6) then
                   tau = 1.0-rc(k,i,j)/(rc(k,i,j)+rp(k,i,j)+eps0)
                   tau = MIN(MAX(tau,eps0),0.9)      
                   phi = k_1 * tau**k_2 * (1.0 - tau**k_2)**3
                   au  = au * (1.0 + phi/(1.0 - tau)**2)
                endif
                !
                ! Khairoutdinov and Kogan
                !
                if (khairoutdinov) then
                   Dc = ( Xc / prw )**(1./3.)
                   au = Cau * (Dc * mmt / 2.)**Eau
                end if

                rpt(k,i,j) = rpt(k,i,j) + au
                npt(k,i,j) = npt(k,i,j) + au/X_bnd
                !
             end if
          end do
       end do
    end do
    
    if (turbulence) then
       do k=1,n1-1
          Resum(k) = Resum(k)/max(1.,Recnt(k))
       end do
       if (sflg) call updtst(n1,'prc',4,Resum,1)
    end if   

  end subroutine auto_SB
  !
  ! ---------------------------------------------------------------------
  ! ACCR_SB calculates the evolution of mass mxng-ratio due to accretion
  ! and self collection following Seifert & Beheng (2001).  Included is 
  ! an alternative formulation for accretion only, following 
  ! Khairoutdinov and Kogan
  !
  subroutine accr_SB(n1,n2,n3,dn0,rc,rp,np,rpt,npt,diss)

    integer, intent (in) :: n1,n2,n3
    real, intent (in)    :: rc(n1,n2,n3), rp(n1,n2,n3), np(n1,n2,n3), dn0(n1)
    real, intent (in)    :: diss(n1,n2,n3)
    real, intent (inout) :: rpt(n1,n2,n3),npt(n1,n2,n3)

    real, parameter :: k_r0 = 4.33  
    real, parameter :: k_1 = 5.e-4 
    real, parameter :: Cac = 67.     ! accretion coefficient in KK param.
    real, parameter :: Eac = 1.15    ! accretion exponent in KK param.

    integer :: i, j, k
    real    :: tau, phi, ac, sc, k_r, epsilon

    do j=3,n3-2
       do i=3,n2-2 
          do k=2,n1-1
             if (rc(k,i,j) > 0. .and. rp(k,i,j) > 0.) then
                tau = 1.0-rc(k,i,j)/(rc(k,i,j)+rp(k,i,j)+eps0)
                tau = MIN(MAX(tau,eps0),1.)
                phi = (tau/(tau+k_1))**4

                k_r = k_r0      
                !Louise: new: add the effect of turbulence on the collision kernel
                !dissipation needs to be converted to cm^2/s^3        
                if (turbulence) then
                   epsilon = min(600.,diss(k,i,j)*1.e4)
                   k_r = k_r*(1+(0.05*epsilon**0.25))
                end if   

                ac  = k_r * rc(k,i,j) * rp(k,i,j) * phi * sqrt(rho_0*dn0(k))
                !
                ! Khairoutdinov and Kogan
                !
                !ac = Cac * (rc(k,i,j) * rp(k,i,j))**Eac
                !
                rpt(k,i,j) = rpt(k,i,j) + ac
                
             end if
             sc = k_r * np(k,i,j) * rp(k,i,j) * sqrt(rho_0*dn0(k))
             npt(k,i,j) = npt(k,i,j) - sc
          end do
       end do
    end do

  end subroutine accr_SB
   !
   ! ---------------------------------------------------------------------
   ! SEDIM_RD: calculates the sedimentation of the rain drops and its
   ! effect on the evolution of theta_l and r_t.  This is expressed in
   ! terms of Dp the mean diameter, not the mass weighted mean diameter
   ! as is used elsewhere.  This is just 1/lambda in the exponential
   ! distribution
   !
   ! 
   ! Louise: subroutine should be replaced with one from LES version 3.1

   subroutine sedim_rd(n1,n2,n3,dt,dn0,rp,np,tk,th,rrate,rtt,tlt,rpt,npt)

     integer, intent (in)                      :: n1,n2,n3
     real, intent (in)                         :: dt
     real, intent (in),    dimension(n1)       :: dn0
     real, intent (in),    dimension(n1,n2,n3) :: rp, np, th, tk
     real, intent (out),   dimension(n1,n2,n3) :: rrate
     real, intent (inout), dimension(n1,n2,n3) :: rtt, tlt, rpt, npt

     real, parameter :: a2 = 9.65       ! in SI [m/s]
     real, parameter :: c2 = 6e2        ! in SI [1/m]
     real, parameter :: Dv = 25.0e-6    ! in SI [m/s]
     real, parameter :: cmur1 = 10.0    ! mu-Dm-relation for rain following
     real, parameter :: cmur2 = 1.20e+3 ! Milbrandt&Yau 2005, JAS, but with
     real, parameter :: cmur3 = 1.5e-3  ! revised constants
     real, parameter :: aq = 6.0e3
     real, parameter :: bq = -0.2
     real, parameter :: an = 3.5e3
     real, parameter :: bn = -0.1


     integer :: i, j, k, kp1, kk, km1
     real    :: b2, Xp, Dp, Dm, mu, flxdiv, tot,sk, mini, maxi, cc, zz, xnpts
     real, dimension(n1) :: nslope,rslope,dn,dr, rfl, nfl, vn, vr, cn, cr, v1

    if(sflg) then
       xnpts = 1./((n3-4)*(n2-4))
       do k=1,n1
          v1(k) = 0.
       end do
    end if

     b2 = a2*exp(c2*Dv)

     do j=3,n3-2
        do i=3,n2-2

           nfl(n1) = 0.
           rfl(n1) = 0.
           do k=n1-1,2,-1
              Xp = rp(k,i,j) / (np(k,i,j)+eps0)
              Xp = MIN(MAX(Xp,X_bnd),X_max)
              ! 
              ! Adjust Dm and mu-Dm and Dp=1/lambda following Milbrandt & Yau
              !
              Dm = ( 6. / (rowt*pi) * Xp )**(1./3.)     
              mu = cmur1*(1.+tanh(cmur2*(Dm-cmur3)))
              Dp = (Dm**3/((mu+3.)*(mu+2.)*(mu+1.)))**(1./3.) 

              vn(k) = sqrt(dn0(k)/1.2)*(a2 - b2*(1.+c2*Dp)**(-(1.+mu)))
              vr(k) = sqrt(dn0(k)/1.2)*(a2 - b2*(1.+c2*Dp)**(-(4.+mu)))
              !
              ! Set fall speeds following Khairoutdinov and Kogan

              if (khairoutdinov) then
                 vn(k) = max(0.,an * Dp + bn)
                 vr(k) = max(0.,aq * Dp + bq)
              end if

           end do

           do k=2,n1-1
              kp1 = min(k+1,n1-1)
              km1 = max(k,2)
              cn(k) = 0.25*(vn(kp1)+2.*vn(k)+vn(km1))*dzi_t(k)*dt
              cr(k) = 0.25*(vr(kp1)+2.*vr(k)+vr(km1))*dzi_t(k)*dt
           end do

           !...piecewise linear method: get slopes
           do k=n1-1,2,-1
              dn(k) = np(k+1,i,j)-np(k,i,j)
              dr(k) = rp(k+1,i,j)-rp(k,i,j)
           enddo
           dn(1)  = dn(2)
           dn(n1) = dn(n1-1)
           dr(1)  = dr(2)
           dr(n1) = dr(n1-1)
           do k=n1-1,2,-1
              !...slope with monotone limiter for np
              sk = 0.5 * (dn(k-1) + dn(k))
              mini = min(np(k-1,i,j),np(k,i,j),np(k+1,i,j))
              maxi = max(np(k-1,i,j),np(k,i,j),np(k+1,i,j))
              nslope(k) = 0.5 * sign(1.,sk)*min(abs(sk), 2.*(np(k,i,j)-mini), &
                   &                                     2.*(maxi-np(k,i,j)))
              !...slope with monotone limiter for rp
              sk = 0.5 * (dr(k-1) + dr(k))
              mini = min(rp(k-1,i,j),rp(k,i,j),rp(k+1,i,j))
              maxi = max(rp(k-1,i,j),rp(k,i,j),rp(k+1,i,j))
              rslope(k) = 0.5 * sign(1.,sk)*min(abs(sk), 2.*(rp(k,i,j)-mini), &
                   &                                     2.*(maxi-rp(k,i,j)))
           enddo

           rfl(n1-1) = 0.
           nfl(n1-1) = 0.
           do k=n1-2,2,-1

              kk = k
              tot = 0.0
              zz  = 0.0
              cc  = min(1.,cn(k))
              do while (cc > 0 .and. kk <= n1-1)
                 tot = tot + dn0(kk)*(np(kk,i,j)+nslope(kk)*(1.-cc))*cc/dzi_t(kk)
                 zz  = zz + 1./dzi_t(kk)
                 kk  = kk + 1
                 cc  = min(1.,cn(kk) - zz*dzi_t(kk))
              enddo
              nfl(k) = -tot /dt

              kk = k
              tot = 0.0
              zz  = 0.0
              cc  = min(1.,cr(k))
              do while (cc > 0 .and. kk <= n1-1)
                 tot = tot + dn0(kk)*(rp(kk,i,j)+rslope(kk)*(1.-cc))*cc/dzi_t(kk)
                 zz  = zz + 1./dzi_t(kk)
                 kk  = kk + 1
                 cc  = min(1.,cr(kk) - zz*dzi_t(kk))
              enddo
              rfl(k) = -tot /dt

              kp1=k+1
              flxdiv = (rfl(kp1)-rfl(k))*dzi_t(k)/dn0(k)
              rpt(k,i,j) =rpt(k,i,j)-flxdiv
              rtt(k,i,j) =rtt(k,i,j)-flxdiv
              tlt(k,i,j) =tlt(k,i,j)+flxdiv*(alvl/cp)*th(k,i,j)/tk(k,i,j)

              npt(k,i,j) = npt(k,i,j)-(nfl(kp1)-nfl(k))*dzi_t(k)/dn0(k)

              rrate(k,i,j)    = -rfl(k) * alvl*0.5*(dn0(k)+dn0(kp1))
              if (sflg) v1(k) = v1(k) + rrate(k,i,j)*xnpts

           end do
        end do
     end do
     if (sflg) call updtst(n1,'prc',1,v1,1)

   end subroutine sedim_rd

   
  !
  ! ---------------------------------------------------------------------
  ! SEDIM_CD: calculates the cloud-droplet sedimentation flux and its effect
  ! on the evolution of r_t and theta_l assuming a log-normal distribution
  ! 
  ! Louise: subroutine should be replaced with one from LES version 3.1
 
  subroutine sedim_cd(n1,n2,n3,dt,th,tk,rc,rrate,rtt,tlt)

    integer, intent (in):: n1,n2,n3
    real, intent (in)                        :: dt
    real, intent (in),   dimension(n1,n2,n3) :: th,tk,rc
    real, intent (out),  dimension(n1,n2,n3) :: rrate
    real, intent (inout),dimension(n1,n2,n3) :: rtt,tlt

    real, parameter :: c = 1.19e8 ! Stokes fall velocity coef [m^-1 s^-1]
    real, parameter :: sgg = 1.2  ! geometric standard dev of cloud droplets

    integer :: i, j, k, kp1
    real    :: Dc, Xc, vc, flxdiv
    real    :: rfl(n1)

    !
    ! calculate the precipitation flux and its effect on r_t and theta_l
    !
    do j=3,n3-2
       do i=3,n2-2 
          rfl(n1) = 0.
          do k=n1-1,2,-1
             Xc = rc(k,i,j) / (CCN+eps0)
             Dc = ( Xc / prw )**(1./3.)
             Dc = MIN(MAX(Dc,D_min),D_bnd)
             vc = min(c*(Dc*0.5)**2 * exp(4.5*(log(sgg))**2),1./(dzi_t(k)*dt))
             rfl(k) = - rc(k,i,j) * vc
             !
             kp1=k+1
             flxdiv = (rfl(kp1)-rfl(k))*dzi_t(k)
             rtt(k,i,j) = rtt(k,i,j)-flxdiv
             tlt(k,i,j) = tlt(k,i,j)+flxdiv*(alvl/cp)*th(k,i,j)/tk(k,i,j)
             rrate(k,i,j) = -rfl(k)  
          end do
       end do
    end do

  end subroutine sedim_cd
 
end module mcrp
