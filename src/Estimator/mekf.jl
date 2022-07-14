# [src/Estimator/mekf.jl]

""" To Do:

 - A (in prediction) does not appear to be correct..., and maybe Hb and Hi, too
 - current_measurement is slow (~ ms)

 - Read up on IMU stuff to get a fill for the noise W and V (I have no idea..) 
 - Read up on setting initial covariances too

 - When in eclipse, dont use I and don't use the Ĩ for z or H either (adjust sizes)
 - Easy functionality for testing (self-consistency, innovation `z` is unbiased noise, etc... )
"""

"""
    MEKF_DATA(Wchol, Vchol)

      Struct containing the process and measurement noise matrices for the
    MEKF. Because this is a square-root MEKF, we are using Cholesky-factorized 
    versions of both W and V. 
"""
struct MEKF_DATA{T}

    Wchol::UpperTriangular{T}      # Process noise for state [ϕ, βᵧ, s, ζ, βₘ]
    Vchol::UpperTriangular{T}      # Measurement noise for measurements [B̃ᴮ, Ĩ]

    function MEKF_DATA(Wchol::UpperTriangular{T}, Vchol::UpperTriangular{T}) where {T}
        """ Primary Constructor """
        new{T}(Wchol, Vchol)
    end

    function MEKF_DATA(; N = 6, σ_mag = deg2rad(20), σ_cur = 0.05, # σ_mag = deg2rad(3.0), σ_cur = 0.1,
                            σs = 1e-5, σζ = deg2rad(0.01), σβₘ = 1e-5,  
                            σC = 1e-5, σα = deg2rad(0.01), σϵ = deg2rad(0.01),
                            gyro_bias_instability = 0.8,   # in deg/hour  
                            angle_random_walk     = 0.06)  # in deg/sqrt(hour)

        """ Generates a new MEKF_DATA by generating the W and V matrices with the provided values """

        ## Process Noise:
        σ_gyro = 5e-4 #deg2rad(gyro_bias_instability) / 3600.0  # Convert (deg/hour) to (rad/sec)
        σ_bias = 3.14e-5 # deg2rad(angle_random_walk) / 60.0        # Convert (deg/sqrt(hour)) to ( rad/sqrt(s) )
        
        # Just using the same bias noise for both 
        W = Diagonal( [σ_gyro * ones(3); σ_bias * ones(3); σs * ones(3); σζ * ones(3); σβₘ * ones(3); σC * ones(N); σα * ones(N); σϵ * ones(N)].^2 )
        Wchol = chol(Matrix(W)) 
        
        ## Measurement Noise:
        V = Diagonal( [σ_mag * ones(3); σ_cur * ones(N)].^2 )
        Vchol = chol(Matrix(V))
    
        MEKF_DATA(Wchol, Vchol)
    end

end

# @warn "Eliminated reset cov!"
@warn "Using iter sqrt MEKF, and no reset cov!"

# May have problems due to re-diagonalizing
"""
    reset_cov!(sat; reset_calibration = true, σϕ = 10*, σβ = 10*, σC = 0.1, σα = 3*, σϵ = 3*)

      Resets the covariances for a satellite (most likely when coming out of eclipse or 
    transitioning between different states). Completely resets the attitude portion, but for the bias 
    the covariance is just increased byt 50%. Can also reset the covariance corresponding to the 
    calibration values if the flag is set to true.

    Note that this covariance uses 3 parameters for the attitude to prevent dropping rank.
"""
function reset_cov!(sat::SATELLITE{N, T}; reset_calibration = false, σϕ = deg2rad(10), σβ = deg2rad(10), 
                        σs = 0.3, σζ = deg2rad(9), σβₘ = deg2rad(12), σC = 0.3, σα = deg2rad(9.0), σϵ = deg2rad(9)) where {N, T}
    
    return nothing
    # # Update Covariances 
    # Reset q, increase β, pass C, α, and ϵ
    Σϕ = diagm( σϕ * ones(3) )  # Reset (remember this is Cholesky so no σ²)
    Σβ = 2.0 * sat.covariance[4:6, 4:6]    # Increase a bit due to unknown propagation in eclipse

    sat.covariance[1:3, 1:3] .= Σϕ
    sat.covariance[4:6, 4:6] .= Σβ

    if reset_calibration 
        # sat.covariance[7:9, 7:9] .= diagm(σs * ones(3))
        # sat.covariance[10:12, 10:12] .= diagm(σζ * ones(3))
        # sat.covariance[13:15, 13:15] .= diagm(σβₘ * ones(3))

        # i₀ = 16; i₁ = i₀ + N - 1
        # sat.covariance[i₀:i₁, i₀:i₁] .= diagm(σC * ones(N))

        # i₀ = i₁ + 1; i₁ = i₀ + N - 1
        # sat.covariance[i₀:i₁, i₀:i₁] .= diagm(σα * ones(N))

        # i₀ = i₁ + 1; i₁ = i₀ + N - 1
        # sat.covariance[i₀:i₁, i₀:i₁] .= diagm(σϵ * ones(N))

        sat.covariance[7:9, 7:9] *= 10 
        sat.covariance[10:12, 10:12] *= 10
        sat.covariance[13:15, 13:15] *= 10

        i₀ = 16; i₁ = i₀ + N - 1
        sat.covariance[i₀:i₁, i₀:i₁] *= 10

        i₀ = i₁ + 1; i₁ = i₀ + N - 1
        sat.covariance[i₀:i₁, i₀:i₁] *= 10

        i₀ = i₁ + 1; i₁ = i₀ + N - 1
        sat.covariance[i₀:i₁, i₀:i₁] *= 10
    end

    return Nothing
end

"""
    estimate(sat, sens, noise, alb, t, dt; use_albedo = true, calibrate = true)

      Calls a single iteration of the multiplicative extended Kalman filter, updating the 
    satellite attitude and bias estimates. Additionally, if the 'calibrate' flag is 
    set to 'true', this updates estimates of the diode calibration factors (C, α, and ϵ).
    Note that this function should NOT be called during eclipses (for now...).

    Arguments:
      - `sat`:    Struct containing current estimate of satellite values      |  SATELLITE
      - `sens`:   Struct containing the most recent sensor measurements       |  SENSORS 
      - `noise`:  Struct containing the noise matrices V, W (as Cholesky)     |  MEKF_DATA
      - `alb`:    Struct containing the reflectivity data for Earth's Albedo  |  ALBEDO 
      - `t`:      Current time, as an Epoch                                   |  Epoch 
      - `dt`:     Size of each time step                                      |  Scalar

      - `E_am₀`:  (Opt) Irradiance of sunlight (TSI - visible & infrared). Default is 1366.0 W/m²  |  Scalar
      - `use_albedo`:  (Opt) Whether or not to factor in Earth's albedo  (defaults to 'true')      |  Bool 
      - `calibrate`:  (Opt) Whether or not to update diode estimates (defaults to 'true')   |  Bool

    Returns:
        - `sat`:  Updated satellite struct containing new estimates           |  SATELLITE
"""  
function estimate(sat::SATELLITE{N, T}, sens::SENSORS{N, T}, noise::MEKF_DATA{T}, alb::ALBEDO, t::Epoch, dt::Real; 
                    E_am₀ = 1366.9, use_albedo = true, calibrate = true) where {N, T}

    # Prepare data 
    sᴵₑ_est = sun_position(t)               # Estimated Sun-Earth vector in inertial frame

    sᴵ_est = sᴵₑ_est - sens.pos             # Estimated sun vector
    Bᴵ_est = SVector{3, T}(IGRF13(sens.pos, t))           # Estimated magnetic field vector in inertial

    # Pass into square-root MEKF 
    Pchol = (calibrate) ? sat.covariance : sat.covariance[1:6, 1:6]
    Wchol = (calibrate) ? noise.Wchol    : UpperTriangular(noise.Wchol[1:6, 1:6])

    # Remember to change reports for self consistency too
    x⁺, mag⁺, diode⁺, Pchol⁺ = iter_sqrt_mekf(sat.state, sat.diodes, sat.magnetometer, Pchol, alb, sens.gyro, Bᴵ_est, sᴵ_est,
                                         sens.magnetometer, sens.diodes, sens.pos, dt, Wchol, noise.Vchol; 
                                         use_albedo = use_albedo, calibrate = calibrate, E_am₀ = E_am₀)

    # Process result and update sat (by making a new copy)
    sat⁺ = SATELLITE(deepcopy(sat.J), mag⁺, diode⁺, x⁺, copy(sat.covariance) )

    if calibrate 
        sat⁺.covariance .= Pchol⁺
    else
        sat⁺.covariance[1:6, 1:6] .= Pchol⁺
    end

    return sat⁺
end

""" sqrt_mekf(x, diodes, Pchol, alb, ω, Bᴵ, sᴵ, B̃ᴮ, Ĩ, pos, dt, W, V; E_am₀, use_albedo, calibrate)

      Runs a single iteration of a square-root multiplicative extended Kalman filter. Can also 
    be used to calibrate diodes if 'calibrate' is set to true. 
"""
function sqrt_mekf(x::SAT_STATE{T}, diodes::DIODES{N, T}, mag::MAGNETOMETER{T}, Pchol::Matrix{T}, alb::ALBEDO, 
                    ω::SVector{3, T}, Bᴵ::SVector{3, T}, sᴵ::SVector{3, T}, B̃ᴮ::SVector{3, T}, 
                    Ĩ::SVector{N, T}, pos::SVector{3, T}, dt::T, W::UpperTriangular, V::UpperTriangular; 
                    E_am₀ = 1366.9, use_albedo = true, calibrate = true) where {N, T}


    ### ITERATION 1 ###
    # Prediction 
    x_pred, A = prediction(x, ω, dt, N; calibrate = calibrate)
    Pchol_pred = qrᵣ([Pchol * A'; W])  # Update covariance (as Cholesky)

    # Measurement (do NOT normalize this, or at least not the current one)
    B̃ᴮ_exp, H_mag = mag_measurement(x_pred, mag, Bᴵ, N; calibrate = calibrate)

    #   If in eclipse, dont use I 
    I_exp,  H_cur = (norm(Ĩ) > 0.05) ?  current_measurement(x_pred, diodes, sᴵ, pos, alb; E_am₀ = E_am₀,
                                                            use_albedo = use_albedo, calibrate = calibrate)  :
                    (calibrate)      ? (zeros(N), zeros(N, 15 + 3 * N)) : (zeros(N), zeros(N, 6))                        

    # Innovation 
    z = [B̃ᴮ - B̃ᴮ_exp; Ĩ - I_exp]
    H = [H_mag; H_cur]
    Pchol_yy = qrᵣ([Pchol_pred * H'; V])
    L = (((Pchol_pred' * Pchol_pred * H') / Pchol_yy) / Pchol_yy')
    x⁺, mag⁺, diodes⁺ = update(x_pred, mag, diodes, L, z; calibrate = calibrate) 

    # Update 
    Pchol⁺ = qrᵣ([ Pchol_pred * (I - L * H)'; V * L']); 

    return x⁺, mag⁺, diodes⁺, Pchol⁺
end

function iter_sqrt_mekf(x::SAT_STATE{T}, diodes::DIODES{N, T}, mag::MAGNETOMETER{T}, Pchol::Matrix{T}, alb::ALBEDO, 
                    ω::SVector{3, T}, Bᴵ::SVector{3, T}, sᴵ::SVector{3, T}, B̃ᴮ::SVector{3, T}, 
                    Ĩ::SVector{N, T}, pos::SVector{3, T}, dt::T, W::UpperTriangular, V::UpperTriangular; 
                    E_am₀ = 1366.9, use_albedo = true, calibrate = true) where {N, T}


    ### ITERATION 1 ###
    # Prediction 
    x_pred, A = prediction(x, ω, dt, N; calibrate = calibrate)
    Pchol_pred = qrᵣ([Pchol * A'; W])  # Update covariance (as Cholesky)

    x⁺, mag⁺, diodes⁺ = deepcopy(x_pred), deepcopy(mag), deepcopy(diodes)
    L, H = 0.0, 0.0

    # Kalman Gain (how much we trust the measurement over the dynamics)
    for _ = 1:3
        # Measurement (do NOT normalize this, or at least not the current one)
        B̃ᴮ_exp, H_mag = mag_measurement(x⁺, mag⁺, Bᴵ, N; calibrate = calibrate)

        #   If in eclipse, dont use I 
        I_exp,  H_cur = (norm(Ĩ) > 0.05) ?  current_measurement(x⁺, diodes⁺, sᴵ, pos, alb; E_am₀ = E_am₀,
                                    use_albedo = use_albedo, calibrate = calibrate)  :
                (calibrate) ? (zeros(N), zeros(N, 15 + 3 * N)) : (zeros(N), zeros(N, 6))                        

        # Innovation 
        z = [B̃ᴮ - B̃ᴮ_exp; Ĩ - I_exp]     # maybe?
        H = [H_mag; H_cur]

        # Update Covariance 
        Pchol_yy = qrᵣ([Pchol_pred * H'; V])
        L = (((Pchol_pred' * Pchol_pred * H') / Pchol_yy) / Pchol_yy')

        x⁺, mag⁺, diodes⁺ = update(x_pred, mag, diodes, L, z; calibrate = calibrate)

    end

    # Update 
    Pchol⁺ = qrᵣ([ Pchol_pred * (I - L * H)'; V * L']); 

    return x⁺, mag⁺, diodes⁺, Pchol⁺
end

function mekf(x::SAT_STATE{T}, diodes::DIODES{N, T}, mag::MAGNETOMETER{T}, Pchol::Matrix{T}, alb::ALBEDO, 
    ω::SVector{3, T}, Bᴵ::SVector{3, T}, sᴵ::SVector{3, T}, B̃ᴮ::SVector{3, T}, 
    Ĩ::SVector{N, T}, pos::SVector{3, T}, dt::T, W::UpperTriangular, V::UpperTriangular; 
    E_am₀ = 1366.9, use_albedo = true, calibrate = true) where {N, T}

    P_prev = Pchol' * Pchol 
    Q = W' * W 
    R = V' * V

    ### ITERATION 1 ###
    # Prediction 
    x_pred, A = prediction(x, ω, dt, N; calibrate = calibrate)
    P_pred = A * P_prev * A' + Q 
    Pchol_pred = qrᵣ([Pchol * A'; W])  # Update covariance (as Cholesky)

    # # Measurement (do NOT normalize this, or at least not the current one)
    B̃ᴮ_exp, H_mag = mag_measurement(x_pred, mag, Bᴵ, N; calibrate = calibrate)

    #   If in eclipse, dont use I 
    I_exp,  H_cur = (norm(Ĩ) > 0.05) ?   current_measurement(x_pred, diodes, sᴵ, pos, alb; E_am₀ = E_am₀,
                                             use_albedo = use_albedo, calibrate = calibrate)  :
                         (calibrate) ? (zeros(N), zeros(N, 15 + 3 * N)) : (zeros(N), zeros(N, 6))                        

    # Innovation 
    z = [B̃ᴮ - B̃ᴮ_exp; Ĩ - I_exp]
    H = [H_mag; H_cur]
    Pxy = P_pred * H' 
    Pyy = H * P_pred * H' + R
    L = Pxy * inv(Pyy)

    # Pchol_yy = qrᵣ([Pchol_pred * H'; V])
    # K = (((Pchol_pred' * Pchol_pred * H') / Pchol_yy) / Pchol_yy')
    x⁺, mag⁺, diodes⁺ = update(x_pred, mag, diodes, L, z; calibrate = calibrate) 

    # x⁺, mag⁺, diodes⁺ = deepcopy(x_pred), deepcopy(mag), deepcopy(diodes)
    # L, H = 0.0, 0.0

    # # Kalman Gain (how much we trust the measurement over the dynamics)
    # for _ = 1:3
    #     # Measurement (do NOT normalize this, or at least not the current one)
    #     B̃ᴮ_exp, H_mag = mag_measurement(x⁺, mag⁺, Bᴵ, N; calibrate = calibrate)

    #     #   If in eclipse, dont use I 
    #     I_exp,  H_cur = (norm(Ĩ) > 0.05) ?  current_measurement(x⁺, diodes⁺, sᴵ, pos, alb; E_am₀ = E_am₀,
    #                                              use_albedo = use_albedo, calibrate = calibrate)  :
    #                          (calibrate) ? (zeros(N), zeros(N, 15 + 3 * N)) : (zeros(N), zeros(N, 6))                        

    #     # Innovation 
    #     z = [B̃ᴮ - B̃ᴮ_exp; Ĩ - I_exp]     # maybe?
    #     H = [H_mag; H_cur]

    #     # Update Covariance 
    #     Pxy = P_pred * H' 
    #     Pyy = H * P_pred * H' + R
    #     L = Pxy * inv(Pyy)
    #     # Pchol_yy = qrᵣ([Pchol_pred * H'; V])
    #     # L = (((Pchol_pred' * Pchol_pred * H') / Pchol_yy) / Pchol_yy')

    #     @infiltrate
    #     x⁺, mag⁺, diodes⁺ = update(x_pred, mag, diodes, L, z; calibrate = calibrate)
    # end

    # Update 
    P_pred⁺ = P_pred - L * H * P_pred
    Pchol⁺ = chol(P_pred⁺) 
    # Pchol⁺_alt = qrᵣ([ Pchol_pred * (I - K * H)'; V * K']); 

    return x⁺, mag⁺, diodes⁺, Pchol⁺
end


# Prediction function that does not use FD
"""
    function prediction(x::SAT_STATE{T}, ω::SVector{3, T}, dt::T, N::Int; calibrate::Bool = true) where {T}

        # Generate axis-angle representation
        γ  = ω - x.β     # Corrected angular velocity 
        nγ = norm(γ)     # Magnitude of corrected angular velocity 

        # Predict next orientation (as a quaternion)
        r  = γ / nγ       # Unit axis of rotation
        θ  = nγ * dt      # Angular rotaation about unit axis
        q⁺ = (nγ == 0.0) ? x.q :
                        qmult(x.q, [cos(θ / 2); r*sin(θ / 2)])  # <- right side is axis-angle to unit quaternion

        # q⁺ = (nγ == 0.0) ? x.q :
        #                    qmult([cos(θ / 2); r*sin(θ / 2)], x.q, )  # <- left side is axis-angle to unit quaternion

        (norm(q⁺) ≉ 1.0) && @infiltrate
        # @assert (norm(q⁺) ≈ 1.0) "Unit quaternion isn't unit!"    
        x⁺ = update_state(x; q = q⁺)  # Doesn't matter if we are calibrating diodes, only q changes in prediction

        # Calculate Jacobian ∂f/∂x

        γ̂ = -hat(γ / nγ)  # Skew-symmetric matrix 
        R = (nγ == 0.0) ? I(3)  :  # Avoid the divide-by-zero error
                          I(3) - (γ̂ ) * sin(θ) + ((γ̂ )^2) * (1 - cos(θ)); # Rodrigues formula

        @debug R ≈ exp(-hat(ω - x.β) * dt)
                        
        A = zeros(T, 6, 6)     # Jacobian of f(x) wrt x,   A  =   [R   -dt I₃;  0₃  I₃]
        A[1:3, 1:3] .= R  # or -hat(ω?)
        A[1:3, 4:6] .= -dt * I(3) 
        A[4:6, 4:6] .= I(3)
        # A[4:6, 1:3] .= zeros(3, 3)

        if calibrate
            # Add in additional states if calibrating (i.e., x = [q, β, C, α, ϵ])
            Ac = zeros(T, 6 + 3 * N, 6 + 3 * N)  # Ac = [A  0; 0 I]
            Ac[1:6, 1:6] .= A 
            Ac[7:end, 7:end] .= I(3 * N)
            
            return x⁺, Ac
        else
            return x⁺, A
        end
    end;

"""

# """
function attitude_jacobian(q)
    G = [-q[2:4]' ; 
        q[1] * I + hat(q[2:4])]
    return SMatrix{4, 3, Float64, 12}(G)
end

""" prediction(x, ω, dt, N; calibrate)

      Predicts the next state and covariance using current state, angular velocity, and time step
    (essentially assumes a small rotation in attitude and that the other states are constant)

    Arguments:
      - `x`:  Current state of the satellite [(q⃗, q₀) β]                    | [7,] 
      - `ω`:  Current angular velocity estimate of the satellite            | [3,]
      - `dt`: Time step of the Simulation                                   |  Scalar
      - `N`:  Number of diodes                                              |  Int
      - `calibrate`: (Opt) Whether or not to calibrate the diodes. Defaults to true.

    Returns:
      - `xn`: Predicted next state  [(q⃗, q₀) β]                             | [7,] 
      - `A`:  Jacobian of dynamics with respect to x                        |  [i x 6 + 3i]
                (Note that the quaternions have been replaced with 3 param)
                    dx/dx = [dϕ/dϕ; dϕ/dβ; ...]                             
"""
function prediction(x::SAT_STATE{T}, ω::SVector{3, T}, dt::T, N::Int; calibrate::Bool = true) where {T}

    function nextq(q, ω, β, dt) 
        
        # Generate axis-angle representation
        γ  = ω - β     # Corrected angular velocity 
        nγ = norm(γ)     # Magnitude of corrected angular velocity 
    
        # Predict next orientation (as a quaternion)
        r  = γ / nγ       # Unit axis of rotation
        θ  = nγ * dt      # Angular rotaation about unit axis
        q⁺ = (nγ == 0.0) ?  q :
                            qmult(q, [cos(θ / 2); r*sin(θ / 2)])

        return q⁺, γ, nγ
    end

    q⁺, γ, nγ = nextq(x.q, ω, x.β, dt)

    x⁺ = update_state(x; q = q⁺)  # Doesn't matter if we are calibrating diodes, only q changes in prediction

    # Calculate Jacobian ∂f/∂x

    # θ = dt * nγ
    # γ̂ = -hat(γ / nγ)  # Skew-symmetric matrix 
    # R = (nγ == 0.0) ? I(3)  :  # Avoid the divide-by-zero error
    #                   I(3) - (γ̂ ) * sin(θ) + ((γ̂ )^2) * (1 - cos(θ)); # Rodrigues formula
    # @debug R ≈ exp(-hat(ω - x.β) * dt) "Error in R!"
            
    
    A = zeros(T, 6, 6)     # Jacobian of f(x) wrt x,   A  =   [R   -dt I₃;  0₃  I₃]

    _nextq_q(_q) = nextq(_q, ω, x.β, dt)[1]
    _nextq_β(_β) = nextq(x.q, ω, _β, dt)[1]

    q⁺ₐ = Array(q⁺) # To prevent FD from somehow overwriting q⁺...
    A[1:3, 1:3] .= attitude_jacobian(q⁺ₐ)' * ForwardDiff.jacobian(_nextq_q, x.q) * attitude_jacobian(x.q)   # df/dq with Attitude Jacobian 
    A[1:3, 4:6] .= attitude_jacobian(q⁺ₐ)' * ForwardDiff.jacobian(_nextq_β, x.β) 
    A[4:6, 4:6] .= I(3)

    
    if calibrate
        # Add in additional states if calibrating (i.e., x = [q, β, C, α, ϵ])
        Ac = zeros(T, 15 + 3 * N, 15 + 3 * N)  # Ac = [A  0; 0 I]
        Ac[1:6, 1:6] .= A 
        Ac[7:end, 7:end] .= I(9 + 3 * N)
        
        return x⁺, Ac
    else
        return x⁺, A
    end
end;
# """


""" mag_measurement(x, Bᴵ, N; calibrate)

      Generates what we would expect our measured magnetic field vector would be in the body frame 
    given our current estimated attitude

    Arguments:
      - `x`:  Current state of the satellite [(q⃗, q₀) β]                 |  [7,] 
      - `Bᴵ`: Mag field vector in the newtonian (inertial) frame         |  [3,]
      - `N`:  Number of diodes (only used if calibrating)                |  Scalar

    Returns:
      - `Bᴮ`: Mag field vector estimate corresponding to state           |  [3,]
      - `H`: Jacobian of mag_measurement with respect to x               |  [3 x 6 (+ 3i)]
                    dy/dx = [dy/dϕ; dy/dβ; ...]                             
"""
function mag_measurement(x::SAT_STATE{T}, mag::MAGNETOMETER{T}, Bᴵ::SVector{3, T}, N::Int; calibrate::Bool = true) where {T}

    ## Generate expected measurements
    Bᴮ = quat2rot(x.q)' * Bᴵ;  # Transpose to convert from inertial → body

    function B(s, ζ, βₘ, Bᴮ)
        a, b, c = s
        ρ, λ, ν = ζ
    
        cal_mat = [a         0.0              0.0;
                   b*sin(ρ)  b*cos(ρ)         0.0;
                   c*sin(λ)  c*sin(ν)*cos(λ)  c*cos(ν)*cos(λ)]
        B̃ᴮ = cal_mat * Bᴮ + βₘ   # What we would expect to measure

        return B̃ᴮ
    end
    
    a, b, c = mag.scale_factors 
    ρ, λ, ν = mag.non_ortho_angles 

    B̃ᴮ = B(mag.scale_factors, mag.non_ortho_angles, mag.bias, Bᴮ)


    # cal_mat = [a         0.0              0.0;
    #            b*sin(ρ)  b*cos(ρ)         0.0;
    #            c*sin(λ)  c*sin(ν)*cos(λ)  c*cos(ν)*cos(λ)]
    # B̃ᴮ = cal_mat * Bᴮ + mag.bias   # What we would expect to measure

    ## Generate Jacobian H (mag_measurement wrt state) 
    ∂ϕ = hat(Bᴮ)  
    ∂βᵧ = zeros(3, 3)

    H = (calibrate) ? zeros(T, 3, 15 + 3 * N) :  # Jacobian Matrix  H = [∂θ ∂β ∂s ∂ζ ∂βₘ ∂C ∂α ∂ϵ]
                      zeros(T, 3, 6)             # Jacobian Matrix  H = [∂θ ∂β] 

    H[:, 1:3] .= ∂ϕ 
    H[:, 4:6] .= ∂βᵧ

    if calibrate
        ∂s = Diagonal([ Bᴮ[1],  
                        Bᴮ[1] * sin(ρ) + Bᴮ[2] * cos(ρ), 
                        Bᴮ[1] * sin(λ) + Bᴮ[2] * cos(λ) * sin(ν) + Bᴮ[3] * cos(λ) * cos(ν)])

        ∂ζ = [0.0      0.0      0.0; 
              b * (Bᴮ[1] * cos(ρ) - Bᴮ[2] * sin(ρ))       0.0       0.0;
              0.0      c * (Bᴮ[1] * cos(λ) - Bᴮ[2] * sin(λ) * sin(ν) - Bᴮ[3] * sin(λ) * cos(ν))    c * (Bᴮ[2] * cos(λ) * cos(ν) - Bᴮ[3] * cos(λ) * sin(ν))]

        ∂βₘ = I(3) 

        H[:, 7:9]   .= ∂s 
        H[:, 10:12] .= ∂ζ
        H[:, 13:15] .= ∂βₘ
        # Remainder are all zero

        # ## REMOVE - TESTING! (It matches)
        # Bs(_s)  = B(_s, mag.non_ortho_angles, mag.bias, Bᴮ)
        # Bζ(_ζ)  = B(mag.scale_factors, _ζ, mag.bias, Bᴮ)
        # Bβ(_βₘ) = B(mag.scale_factors, mag.non_ortho_angles, _βₘ, Bᴮ)
    
        # ds  = ForwardDiff.jacobian(Bs, mag.scale_factors)
        # dζ  = ForwardDiff.jacobian(Bζ, mag.non_ortho_angles)
        # dβₘ = ForwardDiff.jacobian(Bβ, mag.bias)

        # @infiltrate
    end

    return B̃ᴮ, H
end;

""" current_measurement(x, diodes, sᴵ, pos, alb; E_am₀, use_albedo, calibrate)

      Generates what we would expect our measured current values to be given our estimate of state. 
    Earth's albedo can be included, and the state is augmented when the diodes are being calibrated. 

    Arguments:
        - `x`:   Current state of the satellite [(q⃗, q₀) β]              |  [7,] 
        - `diodes`: Struct containing C, α, and ϵ values for diodes      |  DIODES 
        - `sᴵ`:  Sun vector in the newtonian (inertial) frame            |  [3,]
        - `pos`: Position of the satellite (Cartesian, m)                |  [3,]
        - `alb`: Struct containing REFL and cell center data             |  ALBEDO 

        - `E_am₀`:  (Opt) Irradiance of sunlight (TSI - visible & infrared). Default is 1366.0 W/m²   |  Scalar
        - `use_albedo`: (Opt) Whether or not to include the Earth's albedo. Default is true           |  Bool
        - `calibrate`: (Opt) Whether or not to calibrate the diodes too. Default is true       |  Bool

    Returns:
        - Is: Current measurements corresponding to sᴵ & q (non-negative)   |  [i,]
        - H: Jacobian of y with respect to x                                |  [i x 6 (+ 3i)]
                    dy/dx = [dy/dϕ; dy/dβ; ...]                             
"""
function current_measurement(x::SAT_STATE{T}, diodes::DIODES{N, T}, sᴵ::SVector{3, T}, pos::SVector{3, T}, alb::ALBEDO; 
                                E_am₀ = 1366.9, use_albedo = true, calibrate::Bool = true) where {N, T}
    # SUN INERTIAL is UNSCALED NOW!!
    C, α, ϵ = diodes.calib_values, diodes.azi_angles, diodes.elev_angles

    # Generate expected measurements
    sᴵ_unit = sᴵ / norm(sᴵ)  # Unit sun vector in inertial frame
    sᴮ = quat2rot(x.q)' * (sᴵ_unit);  # Transpose to convert from inertial → body
    n = SMatrix{N, 3, Float64, N * 3}([cos.(ϵ).*cos.(α) cos.(ϵ).*sin.(α) sin.(ϵ)]);  # Surface normals for each photodiode
    currents = C .* (n * sᴮ)     # Expected current measurements
    
    albedos  = zeros(T, N)
    if use_albedo
        albedo_matrix = earth_albedo(pos, sᴵ, alb.refl.data)
        for i = 1:N 
            diode_albedo = compute_diode_albedo(albedo_matrix, alb.cell_centers_ecef, n[i, :], pos)  
            albedos[i] = C[i] * (diode_albedo / E_am₀)  
        end
    end

    # Account for eclipses in I, H (a bit problematic for H)
    Is = zeros(T, N)  # This is to deal with the pesky Static problems
    for i = 1:N 
        Is[i] = currents[i] + albedos[i]
    end

    # # Generate Jacobian H (current measurement wrt state)
    ŝᴮ = hat(sᴮ);          # Skew-symmetric 
    ∂θ = (C .* n) * ŝᴮ     # How slight changes in orientation affect expected current field (∂I/∂θ)
    ∂β = zeros(T, N, 3)    # How slight changes in gyro bias affect expected current field (∂I/∂β)
    

    # H = [∂θ ∂β ∂s ∂ζ ∂βₘ ∂C ∂α ∂ϵ]  :  [∂θ ∂β]
    H = (calibrate) ? zeros(T, 6, 15 + 3 * N)  : zeros(T, 6, 6)  
    H[:, 1:3] .= ∂θ
    H[:, 4:6] .= ∂β    # Should be just zeros...

    if calibrate
        # Jacobian Matrix   H = [∂θ ∂β ∂s ∂ζ ∂βₘ ∂C ∂α ∂ϵ]
        ndα = [(-cos.(ϵ).*sin.(α)) ( cos.(ϵ).*cos.(α)) zeros(size(α))];
        ndϵ = [(-sin.(ϵ).*cos.(α)) (-sin.(ϵ).*sin.(α)) cos.(ϵ)]; # (With negative middle term, differing from the paper)
        
        ∂C = n * sᴮ;            # [i,]
        ∂α = C .* (ndα * sᴮ);   # [i,]
        ∂ϵ = C .* (ndϵ * sᴮ);   # [i,]  
        
        H[:, 16:end] .= [Diagonal(∂C) Diagonal(∂α) Diagonal(∂ϵ)]
    end

    Is[Is .< 1e-8]   .= 0.0   # Photodiodes don't generate negative current
    H[Is .≤  0.0, :] .= 0.0   #   ^ to match the above 

    return Is, H
end;


""" update(x, diodes, L, z; calibrate)

      Uses the Kalman gain and innovation vector to update the estimates for the satellite
    state, and potentially the calibration factors too. 
"""
function update(x::SAT_STATE{T}, mag::MAGNETOMETER{T}, diodes::DIODES{N, T}, L::Matrix{T}, z::SVector{N₂, T}; calibrate::Bool = true) where {N, N₂, T}
    
    δx = L * z 

    # Muliplicative portion (orientation) - use axis-angle again
    δϕ = δx[1:3]  
    θ  = norm(δϕ)  # Magnitude of rotation 

    r  = (θ > 0.0) ? (δϕ / θ)  : [0, 0, 0]  # Unit axis of rotation (dealing with 0 rotation)
    δq = SVector{4, T}([cos(θ / 2); r * sin(θ / 2)]) # axis-angle to scalar-first unit quaternion 
    q⁺ = qmult(x.q, δq);  # Rotate a little 

    # Additive portion
    β⁺ = x.β + δx[4:6]
    
    # Update the calibration states if desired
    s⁺  = (calibrate) ? (mag.scale_factors + δx[7:9])      : mag.scale_factors
    ζ⁺  = (calibrate) ? (mag.non_ortho_angles + δx[10:12]) : mag.non_ortho_angles
    βₘ⁺ = (calibrate) ? (mag.bias + δx[13:15])             : mag.bias

    # #### SKETCHY 
    # if s⁺[2] < 0.0 
    #     @infiltrate
    #     s⁺ = s⁺ .* SVector{3, Float64}(1.0, -1.0, 1.0)  # b
    #     ζ⁺ = ζ⁺ .+ SVector{3, Float64}(π, 0.0, 0.0)     # ρ
    # elseif s⁺[3] < 0.0
    #     @infiltrate 
    #     s⁺ = s⁺ .* SVector{3, Float64}(1.0, 1.0, -1.0)  # c
    #     ζ⁺ = ζ⁺ .+ SVector{3, Float64}(0.0, π, 0.0)     # ρ
    # end
    ζ⁺  = atan.(sin.(ζ⁺), cos.(ζ⁺))      # Wrap to (-π, π]

    i₀ = 16; i₁ = i₀ + N - 1
    C⁺ = (calibrate) ? (diodes.calib_values + δx[i₀:i₁]) : diodes.calib_values

    i₀ = i₁ + 1; i₁ = i₀ + N - 1
    α⁺ = (calibrate) ? (diodes.azi_angles  +  δx[i₀:i₁]) : diodes.azi_angles

    i₀ = i₁ + 1; i₁ = i₀ + N - 1
    ϵ⁺ = (calibrate) ? (diodes.elev_angles +  δx[i₀:i₁]) : diodes.elev_angles 


    x⁺ = SAT_STATE(q⁺, β⁺)
    mag⁺ = MAGNETOMETER(s⁺, ζ⁺, βₘ⁺)
    diodes⁺ = DIODES(C⁺, α⁺, ϵ⁺)

    return x⁺, mag⁺, diodes⁺
end




""" 
      Estimates the effect of Earth's albedo on a specific photodiode (by using the surface normal of that diode)
    (NOTE that this comes from the Springmann paper referenced in the Estimator section about photodiode calibration).
    There is also a duplciate version of this in the Simulator/measurements.jl file, kept separate from the Estimator files.
       
      = cell_albedo * surface_normal^T * r_g,
    with r_g as a unit vector in the direction of the grid point on Earth

    Arguments:
      - `data`:   Albedo values for each cell on the Earth's surface  (calculated with EarthAlbedo)   | [num_lat x num_lon] 
      - `cell_centers_ecef`:  Center of each grid cell on Earth's surface (in ECEF)                   | [num_lat x num_lon x 3]
      - `surface_normal`: Photodiode surface normal                                                   | [3,] (Static)
      - `sat_pos`: Cartesian position of satellite                                                    | [3,] (Static)

    Returns:
      - `diode_albedo`: Total effect of albedo on specified photodiode              | Scalar
"""  
function compute_diode_albedo(data::Matrix{T}, cell_centers_ecef::Array{T, 3}, surface_normal::SVector{3, T}, sat_pos::SVector{3, T}) where {T}

    Nlat, Nlon = size(data)

    diode_albedo = 0.0
    r_g = zeros(T, 3)

    for r = 1:Nlat
        for c = 1:Nlon

            if data[r,c] != 0
                r_g .= view(cell_centers_ecef, r, c, :) .- sat_pos
                r_g .= r_g ./ norm(r_g)  # Make unit

                cell_albedo = (data[r,c] * dot(surface_normal, r_g))

                if cell_albedo > 0.0    # Can't be negative
                    diode_albedo += cell_albedo 
                end
            end
        end
    end
    
    return diode_albedo
end

function chol(M)
    return cholesky(Hermitian(M)).U
end

function qrᵣ(M)
    return qr(M).R 
end
