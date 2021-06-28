####################################################################
#               MAGNETOMETER CALIBRATION                           #
####################################################################
# Get rid of sketchy global 
# Seems to occasionally flip sign of ϕ or ϕ (guesses negative of one?)

# Should I only pass in some?
struct MAG_CALIB 
    mag_field_meas 
    mag_field_pred
end

######### SKETCHY 
mag_field_meas_hist = 0 
mag_field_pred_hist = 0
curr_hist = 0 
A = 0 
################

# Currently does NOT include time-varying current-induced bias (assume we turn off everything while calibrating) -> Check out initial commit for version with currents included 
function estimate_vals(sat::SATELLITE, data::MAG_CALIB)
    """ Sat ESTIMATE not truth """

    if isempty(size(mag_field_meas_hist))  # Initialize   
        global mag_field_meas_hist = data.mag_field_meas[:]    
        global mag_field_pred_hist = data.mag_field_pred[:]   
        global A = [(data.mag_field_pred[1]*I(3))       (data.mag_field_pred[2]*I(3))[:, 2:3]       (data.mag_field_pred[3]*I(3))[:, 3]    I(3)]
    else 
        global mag_field_meas_hist = [mag_field_meas_hist[:]; data.mag_field_meas[:]] # Store as vector
        global mag_field_pred_hist = [mag_field_pred_hist[:]; data.mag_field_pred[:]] # Store as vector
        new_row =  [(data.mag_field_pred[1]*I(3))       (data.mag_field_pred[2]*I(3))[:, 2:3]       (data.mag_field_pred[3]*I(3))[:, 3]    I(3)]

        global A = [A; new_row]
    end

    # If we have enough data to math...
    if (size(A, 1) > 60) # && ((size(A,1) % 480) == 0) # Needs to be overconstrained, and GN is slow so do it periodically 
    
        params = A \ mag_field_meas_hist 
        
        params = gauss_newton(params, data)

        mag_calib_matrix_est, β = parameters_to_matrix_bias(params)
        bx_est, by_est, bz_est = β[:]
        a_est, b_est, c_est, ρ_est, λ_est, ϕ_est = extract_parameters(mag_calib_matrix_est)

        # Check for change 
        δscale_factors = sum(abs.(sat.magnetometer.scale_factors - [a_est, b_est, c_est]))
        δnon_ortho = sum(abs.(sat.magnetometer.non_ortho_angles - [ρ_est, λ_est, ϕ_est]))
        δbias = sum(abs.(sat.magnetometer.bias - [bx_est, by_est, bz_est]))

        new_guesses = A * params;

        idx = 0
        error = 0 
        for j = 1:Int(length(new_guesses)/3)
            idx += 1
            I⁰ = (idx * 3) - 2
            Iᶠ = (idx * 3)
            est = norm(new_guesses[I⁰:Iᶠ])
            meas = norm(mag_field_meas_hist[I⁰:Iᶠ])

            error = abs(est - meas)
        end
        # println("Mean Reprojection Error: ", (error / idx), " change: ", (δscale_factors + δnon_ortho))

        # if (δscale_factors < 0.001) && (δnon_ortho < 0.001) && (δbias < 0.01) 
        # if (error / idx) < 0.25 && (δscale_factors + δnon_ortho) < 0.1
        if (δscale_factors + δnon_ortho) < 0.1
            println("FINISHED Mag Calib!")
            finished = true 
        else 
            finished = false 
        end

        # UPDATE SATELLITE ESTIMATES
        updated_magnetometer_est = MAGNETOMETER([a_est, b_est, c_est], 
                                                [ρ_est, λ_est, ϕ_est],
                                                [bx_est, by_est, bz_est] )
        sat.magnetometer = updated_magnetometer_est


        # PLOT IF FINISHED??

        return sat, finished
    end

    # Otherwise
    return sat, data, false
end

function initialize(data::MAG_CALIB)
    return data
end

function extract_parameters(T)
    a = T[1,1] # Easy 

    b = sqrt((T[2,1]^2) + (T[2,2]^2)) # (bsin)^2 + (bcos)^2 = b^2
    ρ = atan(T[2,1], T[2,2]) # sin/cos to maintain signs

    c = sqrt((T[3,1]^2) + (T[3,2]^2) + (T[3,3]^2))
    ϕ = atan(T[3,2] / T[3,3])
    λ = atan(  sign(T[3,1]) * sqrt( (T[3,1]^2) ),  
               sign((T[3,2]^2) + (T[3,3]^2)) * sqrt( (T[3,2]^2) + (T[3,3]^2) ) ) # Not positve this portion of the sign is actually useful

    return a, b, c, ρ, λ, ϕ
end

function parameters_to_matrix_bias(p)
    # params | [9 x 1] => Lower triangular & bias vector
    T = [p[1]   0       0;
         p[2]   p[4]    0;
         p[3]   p[5]    p[6]];      # Calibration matrix

    β = p[7:9];     # Bias vector 

    return T, β[:]
end

function f(bm, p)
    # Reshape p -> T, b, s 
    T_hat, bias_hat =  parameters_to_matrix_bias(p)

    # B_meas = TB + b + Sum(s*I_meas)
    # -> B = T^-1(B_meas - b - sum)


    B = (T_hat^(-1))*(bm - bias_hat)
    B_squared = (B[1]^2) + (B[2]^2) + (B[3]^2)
    return B_squared
end

# USES GLOBALS -> Pass in ?
# Fix the strange indexing 
function residual(x)
    ### UPDATE 
    """ residual vector for Gauss-Newton. rᵀr = MAP cost function
            Note that x = parameters 
            Meas = [(B_meas, B_pred) x T]
            Loss Function: 
               J = 0.5*(B^2 - f(B,I,x))^T(B^2 - f(B,I,x))
    """
    N = Int(size(mag_field_meas_hist, 1) / 3)  # stored as [x₁ y₁ z₁ x₂ y₂ .....] so we need to divide by 3 
    r = zeros(eltype(x), (N))
    
    for i = 1:N
        B_meas = mag_field_meas_hist[(3*i - 2):(3*i)]
        B_exp_squared = (mag_field_pred_hist[(3*i - 2)]^2) + (mag_field_pred_hist[(3*i - 1)]^2) + (mag_field_pred_hist[(3*i)]^2) # Should be [M x 1] -> Should M > 1?

        J = ((B_exp_squared) - f(B_meas, x)) 
        # J = 0.5 * (B_exp_squared - f(B_meas, x))' * (B_exp_squared - f(B_meas, x))

        r[i] =  J # invcholQ * J?
    end

    return reshape(r, length(r))
end

function gauss_newton(x0, data::MAG_CALIB)
    """Gauss-Newton for batch estimation"""

    # copy initial guess
    x = copy(x0)

    # create sparse jacobian
    # J = spzeros(nx*(T-1) + m*(T),nx*T)

    Ds = 0.0
    v = zeros(length(x))

    # run Gauss-Newton for 100 iterations max
    for i = 1:50

        # ∂r/∂x
        _res(x) = residual(x) # residual(x, data)
        J = ForwardDiff.jacobian(_res, x)

        # calculate residual at x
        r = _res(x)

        # solve for Gauss-Newton step (direct, or indirect)
        v = -J\r
        # lsqr!(v,-J,r)

        # calculate current cost
        S_k = dot(r,r)
        # @show S_k

        # step size (learning rate)
        α = 1.0

        # run a simple line search
        for ii = 1:25
            x_new = x + α*v
            S_new= norm(_res(x_new))^2

            # this could be updated for strong frank-wolfe conditions
            if S_new < S_k
                x = copy(x_new)
                Ds = S_k - S_new
                # @show ii
                break
            else
                α /= 2
            end
            if ii == 25
                # @warn "line search failed"
                Ds = 0

            end
        end

        # depending on problems caling, termination criteria should be updated
        if Ds < 1e-5
            break
        end

        # ----------------------------output stuff-----------------------------
        # if rem((i-1),4)==0
        #     println("iter      α           S          dS")
        # end
        S_display = round(S_k,sigdigits = 3)
        dS_display = round(Ds,sigdigits = 3)
        alpha_display = round(α,sigdigits = 3)
        # println("$i         $alpha_display   $S_display    $dS_display")

    end
    return x
end