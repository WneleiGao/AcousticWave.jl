import Base.zeros
function zeros(path::String , nz::Int64, nx::Int64, ot::Float64, dt::Float64, nt::Int64)
    fid = open(path, "w")
    write(fid, nz, nx, ot, dt, nt)
    write(fid, zeros(nz*nx*nt))
    close(fid)
    return nothing
end


import Base.ones
function ones(path::String , nz::Int64, nx::Int64, ot::Float64, dt::Float64, nt::Int64)
    fid = open(path, "w")
    write(fid, nz, nx, ot, dt, nt)
    write(fid, ones(nz*nx*nt))
    close(fid)
    return nothing
end


function dotSrcSpt(path::String )
    (nz, nx, ot, dt, nt) =  InfoSrcSpt(path)
    fid = open(path, "r")
    seek(fid, sizeof(Float64)*5)
    l = 0.0
    for it = 1 : nt
        p = read(fid, Float64, nz*nx)
        l = l + dot(p,p)
    end
    close(fid)
    return l
end


function dotSrcSpt(path::String , W::Array{Float64,1})
    (nz, nx, ot, dt, nt) =  InfoSrcSpt(path)
    if nz*nx != length(W)
       error("size dismatch")
    end
    fid = open(path, "r")
    seek(fid, sizeof(Float64)*5)
    l = 0.0
    for it = 1 : nt
        p = read(fid, Float64, nz*nx)
        l = l + dot(p, W.*p)
    end
    close(fid)
    return l
end


function AddSrcSpt(path1::String , path2::String , alpha::Float64; item=2)
    (nz1, nx1, ot1, dt1, nt1) = InfoSrcSpt(path1)
    (nz , nx , ot , dt , nt ) = InfoSrcSpt(path2)
    if nz1 != nz || nx1 != nx || nt1 != nt
       error("size dismatch of those two srcspts")
    end
    fid1 = open(path1, "r+")
    fid2 = open(path2, "r" )
    head = sizeof(Float64) * 5
    lspt = sizeof(Float64) * nz * nx
    if item == 1
       for it = 1 : nt
           position = head + (it-1)*lspt
           seek(fid1, position)
           seek(fid2, position)
           p1 = read(fid1, Float64, nz*nx)
           p2 = read(fid2, Float64, nz*nx)
           p1 = alpha*p1 + p2
           seek(fid1, position)
           write(fid1, p1)
       end
    elseif item == 2
       for it = 1 : nt
           position = head + (it-1)*lspt
           seek(fid1, position)
           seek(fid2, position)
           p1 = read(fid1, Float64, nz*nx)
           p2 = read(fid2, Float64, nz*nx)
           p1 = p1 + alpha * p2
           seek(fid1, position)
           write(fid1, p1)
       end
    end
    close(fid1); close(fid2);
    return nothing
end


function CGjoint(ntw::Int64, path_x::String , path_s::String , path_p::String , shot::Shot, fidMtx::FidMtx, pos_rec::Array{Int64,2}; niter=10, mu=0.1, tmax=0.5)
    cost = zeros(niter+1)
    nz = fidMtx.nz; nx = fidMtx.nx; dt = fidMtx.dt
    zeros(path_x, nz, nx, 0.0, dt, ntw)
    shot_r = copy(shot)                            #r = b - A*x
    MultiStepAdjoint(ntw, path_s, shot_r, fidMtx)  #s = A'*r - mu*x
    cp(path_s, path_p, remove_destination=true)    #p = s
    gamma = dotSrcSpt(path_s)                      #gamma = s'*s
    cost0 = dot(vec(shot_r.d), vec(shot_r.d))      #||b-Ax||_2^2
    cost[1] = 1.0
    println("iteration 0, objective 1")
    for k = 1 : niter
        shot_q = MultiStepForward(pos_rec, path_p, fidMtx, tmax=tmax)           # q = A*p
        delta = dot(vec(shot_q.d), vec(shot_q.d)) + mu * dotSrcSpt(path_p)      # delta = q'*q + mu*p'*p
        if delta <= 0
           println("waring: indefinite")
        end
        alpha = gamma / delta
        AddSrcSpt(path_x, path_p, alpha)
        shot_r.d = shot_r.d - alpha*(shot_q.d)
        rm(path_s)
        MultiStepAdjoint(ntw, path_s, shot_r, fidMtx)
        AddSrcSpt(path_s, path_x, -mu)                                          # s = A'*r - mu*x
        gamma0 = copy(gamma)                                                    # gamma0 = gamma
        gamma  = dotSrcSpt(path_s)                                              # gammas = s'*s
        df = dot(vec(shot_r.d), vec(shot_r.d)); mnorm = mu*dotSrcSpt(path_x)
        ratio = mnorm / df
        cost1  = (df + mnorm) / cost0
        cost[k+1] = cost1
        println("iteration $k, objective $cost1, ratio $ratio")
        beta = gamma / gamma0
        AddSrcSpt(path_p, path_s, beta, item=1)                                 #p = s + beta*p
    end
    return cost
end

function GPW(path_x::String )
    (nz, nx, ot, dt, ntw) = InfoSrcSpt(path_x)
    fid = open(path_x, "r")
    seek(fid, sizeof(Float64)*5)
    W = zeros(nz*nx)
    for it = 1 : ntw
        p  = read(fid, Float64, nz*nx)
        W  = W + p.^2
    end
    W = sqrt(W); delta = 10e-12
    W = 1 ./ (W+delta)
    W = W / maximum(W)
    return W
end

function obtainS(path_s::String , mu::Float64, W::Array{Float64,1}, path_x::String )
    # compute s = s - mu*W*x
    tmp = mu * W
    (nz1, nx1, ot, dt, ntw1) = InfoSrcSpt(path_s)
    (nz , nx , ot, dt, ntw ) = InfoSrcSpt(path_x)
    if nz1 != nz || nx1 != nx || ntw1 != ntw
       error("size dismatch")
    end
    fids = open(path_s, "r+");
    fidx = open(path_x, "r" );
    for it = 1 : ntw
        pos = sizeof(Float64)*(5 + nz*nx*(it-1))
        seek(fids, pos);
        seek(fidx, pos);
        ps = read(fids, Float64, nz*nx)
        px = read(fidx, Float64, nz*nx)
        ps = ps - (tmp.*px)
        seek(fids, pos)
        write(fids, ps)
    end
    return nothing
end

function regnorm(mu::Float64, W::Array{Float64,1}, path_x::String )
    (nz, nx, ot, dt, ntw) = InfoSrcSpt(path_x)
    fid = open(path_x, "r")
    seek(fid, sizeof(Float64)*5)
    x = zeros(nz*nx)
    value = 0.0
    for it = 1 : ntw
        x  = read(fid, Float64, nz*nx)
        value = value + dot(x, W.*x)
    end
    value = mu * value
    return value
end

function CG_GP(W::Array{Float64,1}, ntw::Int64, path_x::String , path_s::String , path_p::String , shot_b::Shot, fidMtx::FidMtx, pos_rec::Array{Int64,2}; niter=10, mu=0.1, tmax=0.5)
    nz = fidMtx.nz; nx = fidMtx.nx; dt = fidMtx.dt
    shot_r = shot_b - MultiStepForward(pos_rec, path_x, fidMtx, tmax=tmax)
    MultiStepAdjoint(ntw, path_s, shot_r, fidMtx)
    obtainS(path_s, mu, W, path_x)
    cp(path_s, path_p, remove_destination=true)
    gamma = dotSrcSpt(path_s)
    cost0 = dot(vec(shot_r.d), vec(shot_r.d)) + regnorm(mu, W, path_x)
    println("iteration 0, objective 1")
    for k = 1 : niter
        shot_q = MultiStepForward(pos_rec, path_p, fidMtx, tmax=tmax)
        delta = dot(vec(shot_q.d), vec(shot_q.d)) + regnorm(mu, W, path_p)
        if delta <= 0
           println("waring: indefinite")
        end
        if delta == 0
           delta = eps()
        end
        alpha = gamma / delta
        AddSrcSpt(path_x, path_p, alpha)
        shot_r.d = shot_r.d - alpha*(shot_q.d)
        rm(path_s)
        MultiStepAdjoint(ntw, path_s, shot_r, fidMtx)
        obtainS(path_s, mu, W, path_x)
        gamma0 = gamma
        gamma  = dotSrcSpt(path_s)
        df = dot(vec(shot_r.d), vec(shot_r.d)); mnorm = regnorm(mu, W, path_x)
        ratio = mnorm / df
        cost1  = (df + mnorm) / cost0
        println("iteration $k, objective $cost1, dataFit/modelNorm $ratio")
        beta = gamma / gamma0
        AddSrcSpt(path_p, path_s, beta, item=1)
    end
    return nothing
end

function CGjoint_GP(ntw::Int64, path_x::String , path_s::String , path_p::String , shot::Shot, fidMtx::FidMtx, pos_rec::Array{Int64,2}; inner=5, outer=5, mu=0.1, tmax=0.5)
    # obj = CGjoint(ntw, path_x, path_s, path_p, shot, fidMtx, pos_rec, tmax=tmax, mu=mu, niter=inner)
    nz = fidMtx.nz; nx = fidMtx.nx;
    MultiStepAdjoint(ntw, path_x, shot, fidMtx)
    W = zeros(nz*nx)
    for iter = 1 : outer
        W = GPW(path_x)
        CG_GP(W, ntw, path_x, path_s, path_p, shot, fidMtx, pos_rec, niter=inner, mu=mu, tmax=tmax)
        rm(path_s)
        rm(path_p)
    end
    return W
end

function engdis(path_x::String )
    (nz, nx, ot, dt, ntw) = InfoSrcSpt(path_x)
    fid = open(path_x, "r")
    seek(fid, sizeof(Float64)*5)
    W = zeros(nz*nx)
    for it = 1 : ntw
        p  = read(fid, Float64, nz*nx)
        W  = W + p.^2
    end
    W = reshape(W, nz, nx)
    return W
end
