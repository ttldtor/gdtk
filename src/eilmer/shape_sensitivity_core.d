/** shape_sensitivity_core.d
 * 
 * Eilmer4 shape sensitivity calculator core functions.
 *
 * Author: Kyle D.
**/

module shape_sensitivity_core;

import core.memory;
import std.stdio;
import std.math;
import std.process;
import std.algorithm;
import std.string;
import std.file;
import std.parallelism;
import std.conv;

import util.lua;
import util.lua_service;

import nm.bbla;
import nm.smla;
import nm.luabbla;
import nm.complex;
import nm.number;

import steadystate_core;
import fluidblock;
import sfluidblock;
import ufluidblock;
import fvcell;
import fvinterface;
import fvvertex;
import globaldata;
import globalconfig;
import bc;
import onedinterp;
import lsqinterp;
import grid_deform;
import fvcore;
import fileutil;
import geom;
import geom.luawrap;
import lua_helper;
import simcore;
import fluxcalc;
import user_defined_source_terms;

enum ghost_cell_start_id = 1_000_000_000;
immutable double ESSENTIALLY_ZERO = 1.0e-50;
// some data objects used in forming the Jacobian
immutable size_t MAX_PERTURBED_INTERFACES = 40;
FVCell cellSave;
FVInterface[MAX_PERTURBED_INTERFACES] ifaceP;

// Module-local, global memory arrays and matrices for GMRES
number[] g0;
number[] g1;
number[] h;
number[] hR;
Matrix!number H0;
Matrix!number H1;
Matrix!number Gamma;
Matrix!number Q0;
Matrix!number Q1;

private lua_State* L; // module-local Lua interpreter

/**********************/
/* Frechet Derivative */
/**********************/
void evalJacobianVecProd(FluidBlock blk, size_t nPrimitive, number[] v, ref number[] p, number EPS) {
    blk.clear_fluxes_of_conserved_quantities();
    foreach (cell; blk.cells) cell.clear_source_vector();
    int cellCount = 0;
    foreach (cell; blk.cells) {
        cell.fs.gas.rho += EPS*v[cellCount+0];
        cell.fs.vel.refx += EPS*v[cellCount+1];
        cell.fs.vel.refy += EPS*v[cellCount+2];
        cell.fs.gas.p += EPS*v[cellCount+3];
        blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);
        blk.myConfig.gmodel.update_trans_coeffs(cell.fs.gas);
        cellCount += nPrimitive;
    }    
    steadystate_core.evalRHS(0.0, 0);
    cellCount = 0;
    foreach (cell; blk.cells) {
        p[cellCount+0] = cell.dUdt[0].mass.im/EPS.im; 
        p[cellCount+1] = cell.dUdt[0].momentum.x.im/EPS.im;
        p[cellCount+2] = cell.dUdt[0].momentum.y.im/EPS.im; 
        p[cellCount+3] = cell.dUdt[0].total_energy.im/EPS.im;
        cellCount += nPrimitive;
    }
}

/***************************/
/* FLOW JACOBIAN FUNCTIONS */
/***************************/
string computeGhostCellDerivatives(string varName, string posInArray, bool includeThermoUpdate)
{
    string codeStr;
    codeStr ~= "cellSave.copy_values_from(bcells[0], CopyDataOption.all);";
    // ------------------ positive perturbation ------------------
    codeStr ~= "bcells[0].fs."~varName~" += EPS;";
    if ( includeThermoUpdate ) {
        codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(bcells[0].fs.gas);";
    }
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "qP[0] = pcell.fs.gas.rho;";
    codeStr ~= "qP[1] = pcell.fs.vel.x;";
    codeStr ~= "qP[2] = pcell.fs.vel.y;";
    codeStr ~= "qP[3] = pcell.fs.gas.p;";
    codeStr ~= "bcells[0].copy_values_from(cellSave, CopyDataOption.all);";
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    // ------------------ compute interface flux derivatives ------------------
    codeStr ~= "dqdQ[0][" ~ posInArray ~ "] = qP[0].im/(EPS.im);";
    codeStr ~= "dqdQ[1][" ~ posInArray ~ "] = qP[1].im/(EPS.im);";
    codeStr ~= "dqdQ[2][" ~ posInArray ~ "] = qP[2].im/(EPS.im);";
    codeStr ~= "dqdQ[3][" ~ posInArray ~ "] = qP[3].im/(EPS.im);";         
    return codeStr;
}

void apply_boundary_conditions(ref SMatrix!number A, FluidBlock blk, size_t np, size_t orderOfJacobian, number EPS) {
    // initialise some re-used data objects here
    number[][] dRdq; number[][] dqdQ; number[][] Aext; number[] qP;
    qP.length = np; dRdq.length = np; dqdQ.length = np; Aext.length = np; 
    foreach (ref a; dRdq) a.length = np;
    foreach (ref a; dqdQ) a.length = np;
    foreach (ref a; Aext) a.length = np;

    foreach ( bndary; blk.bc ) {
        if (bndary.type != "exchange_using_mapped_cells") {
            foreach ( bi, bface; bndary.faces) {                
                // collect interior boundary cells (bcells) and exterior ghost cell (pcell)
                FVCell[] bcells; FVCell pcell;
                if (bndary.outsigns[bi] == 1) {
                    bcells ~= bface.left_cell;
                    pcell = bface.right_cell;
                } else {
                    bcells ~= bface.right_cell;
                    pcell = bface.left_cell;
                }
                
                /* form dqdQ - ghost cell derivatives */

                // 0th perturbation: rho
                mixin(computeGhostCellDerivatives("gas.rho", "0", true));
                // 1st perturbation: u
                mixin(computeGhostCellDerivatives("vel.refx", "1", false));
                // 2nd perturbation: v
                mixin(computeGhostCellDerivatives("vel.refy", "2", false));
                // 3rd perturbation: P
                mixin(computeGhostCellDerivatives("gas.p", "3", true));

                /* form dRdq */
                
                // TODO: Currently only works for nearest-neighbour reconstruction stencil. Think about the MLP limiter.
                if (orderOfJacobian > 1 || GlobalConfig.viscous) {
                    size_t[] idList;
                    foreach ( face; bcells[0].iface) {
                        FVCell lftCell = face.left_cell;
                        FVCell rghtCell = face.right_cell;
                        if (lftCell.id != bcells[0].id && idList.canFind(lftCell.id) == false && lftCell.id < ghost_cell_start_id) {
                            bcells ~= lftCell;
                            idList ~= lftCell.id;
                        }
                        if (rghtCell.id != bcells[0].id && idList.canFind(rghtCell.id) == false && rghtCell.id < ghost_cell_start_id) {
                            bcells ~= rghtCell; 
                            idList ~= rghtCell.id;
                        }
                    }
                }
                
                pcell.jacobian_cell_stencil ~= bcells;
                size_t[] idList;
                foreach ( bcell; bcells) {
                    foreach ( face; bcell.iface) {
                        if ( idList.canFind(face.id) == false ) {
                            pcell.jacobian_face_stencil ~= face;
                            idList ~= face.id;
                        }
                    }
                }
                
                // 0th perturbation: rho
                mixin(computeFluxDerivativesAroundCell("gas.rho", "0", true));
                // 1st perturbation: u
                mixin(computeFluxDerivativesAroundCell("vel.refx", "1", false));
                // 2nd perturbation: v
                mixin(computeFluxDerivativesAroundCell("vel.refy", "2", false));
                // 3rd perturbation: P
                mixin(computeFluxDerivativesAroundCell("gas.p", "3", true));
                foreach(bcell; pcell.jacobian_cell_stencil) {
                    number integral;
                    number volInv = 1.0 / bcell.volume[0];
                    for ( size_t ip = 0; ip < np; ++ip ) {
                        for ( size_t jp = 0; jp < np; ++jp ) {
                            integral = 0.0;
                            foreach(fi, iface; bcell.iface) {
                                integral -= bcell.outsign[fi] * iface.dFdU[ip][jp] * iface.area[0]; // gtl=0
                            }
                            number entry = volInv * integral;                    
                            dRdq[ip][jp] = entry;
                        }
                    }

                    //writeln(dRdq);
                    
                    // perform matrix-matrix multiplication
                    for (size_t i = 0; i < np; i++) {
                        for (size_t j = 0; j < np; j++) {
                            Aext[i][j] = 0;
                            for (size_t k = 0; k < np; k++) {
                                Aext[i][j] += dRdq[i][k]*dqdQ[k][j];
                            }
                        }
                    }
                    
                    // add correction to boundary entry in Jacobian
                    size_t I, J;
                    for ( size_t ip = 0; ip < np; ++ip ) {
                        I = bcell.id*np + ip; // column index
                        for ( size_t jp = 0; jp < np; ++jp ) {
                            J = bcells[0].id*np + jp; // row index
                            A[J,I] = A[J,I] + Aext[ip][jp];
                        }
                    }
                }
                    
                // clear the interface flux Jacobian entries
                foreach (iface; pcell.jacobian_face_stencil) {
                    foreach (i; 0..iface.dFdU.length) {
                        foreach (j; 0..iface.dFdU[i].length) {
                            iface.dFdU[i][j] = 0.0;
                        }
                    }
                }
                
                pcell.jacobian_cell_stencil = [];
                pcell.jacobian_face_stencil = [];
            }
        }
    }
}

 
void residual_stencil(FVCell pcell, size_t orderOfJacobian) {

    if (orderOfJacobian == 0) {
        pcell.jacobian_cell_stencil ~= pcell; 
        foreach(face; pcell.iface) {
            pcell.jacobian_face_stencil ~= face;
        }
    }
    else if (orderOfJacobian == 1 && GlobalConfig.viscous == false) {
        FVCell[] refs_ordered; FVCell[] refs_unordered;
        size_t[size_t] pos_array; // used to identify where the cell is in the unordered list
        size_t[] cell_ids;
        
        // clear the stencil arrays
        pcell.jacobian_cell_stencil = [];
        pcell.jacobian_face_stencil = [];
        
        // collect faces
        foreach(face; pcell.iface) {
            pcell.jacobian_face_stencil ~= face;
        }
        
        // for each effected face, add the neighbouring cells
        foreach(face; pcell.jacobian_face_stencil) {
            // collect (non-ghost) neighbour cells
            if (cell_ids.canFind(face.left_cell.id) == false && face.left_cell.id < ghost_cell_start_id) {
                refs_unordered ~= face.left_cell;
                pos_array[face.left_cell.id] = refs_unordered.length-1;
                cell_ids ~= face.left_cell.id;
            }
            if (cell_ids.canFind(face.right_cell.id) == false && face.right_cell.id < ghost_cell_start_id) {
                refs_unordered ~= face.right_cell;
                pos_array[face.right_cell.id] = refs_unordered.length-1;
                cell_ids ~= face.right_cell.id;
            }
            else continue;
        }
        
        // sort ids, and store sorted cell references
        cell_ids.sort();
        foreach(id; cell_ids) refs_ordered ~= refs_unordered[pos_array[id]];
        pcell.jacobian_cell_stencil ~= refs_ordered;
    }
    else { // 2nd order || viscous || 2nd order + viscous
        FVCell[] refs_ordered; FVCell[] refs_unordered;
        size_t[size_t] pos_array; // used to identify where the cell is in the unordered list
        size_t[] cell_ids; size_t[] face_ids;
        
        foreach(cell; pcell.cell_cloud) {
            // collect faces
            foreach(face; cell.iface) {
                if (face_ids.canFind(face.id) == false) {
                    pcell.jacobian_face_stencil ~= face;
                    face_ids ~= face.id;
                }
            }
        }
        
        // for each effected face, add the neighbouring cells
        foreach(face; pcell.jacobian_face_stencil) {
            // collect (non-ghost) neighbour cells
            if (cell_ids.canFind(face.left_cell.id) == false && face.left_cell.id < ghost_cell_start_id) {
                refs_unordered ~= face.left_cell;
                pos_array[face.left_cell.id] = refs_unordered.length-1;
                cell_ids ~= face.left_cell.id;
            }
            if (cell_ids.canFind(face.right_cell.id) == false && face.right_cell.id < ghost_cell_start_id) {
                refs_unordered ~= face.right_cell;
                pos_array[face.right_cell.id] = refs_unordered.length-1;
                cell_ids ~= face.right_cell.id;
            }
            else continue;
        }
        
        // finally sort ids, and store sorted cell references
        cell_ids.sort();
        foreach(id; cell_ids) {
            refs_ordered ~= refs_unordered[pos_array[id]];
        }
        pcell.jacobian_cell_stencil ~= refs_ordered;            
    }
}

void local_flow_jacobian_transpose(ref SMatrix!number A, FluidBlock blk, size_t np, size_t orderOfJacobian, number EPS) {

    // set the interpolation order to that of the Jacobian
    if (orderOfJacobian < 2) blk.myConfig.interpolation_order = 1;
    else blk.myConfig.interpolation_order = 2;    

    // initialise re-used objects here to prevent memory bloat
    cellSave = new FVCell(blk.myConfig);
    foreach(i; 0..MAX_PERTURBED_INTERFACES) ifaceP[i] = new FVInterface(blk.myConfig, false);

    foreach (cell; blk.cells) residual_stencil(cell, orderOfJacobian);

    number[][] aa; size_t[][] ja; size_t ia = 0;
    foreach(cell; blk.cells) {
        aa.length = np; ja.length = np;
        compute_flow_jacobian_rows_for_cell(aa, ja, cell, blk, np, orderOfJacobian, EPS);
        foreach (i; 0 .. np ) {
            A.aa ~= aa[i];
            A.ja ~= ja[i];
            A.ia ~= ia;
            ia += aa[i].length;
        }
        aa = [][];
        ja = [][];
    }
    A.ia ~= A.aa.length;

    apply_boundary_conditions(A, blk, np, orderOfJacobian, EPS);

    // reset the interpolation order
    blk.myConfig.interpolation_order = GlobalConfig.interpolation_order;
}

void compute_flow_jacobian_rows_for_cell(number[][] aa, size_t[][] ja, FVCell pcell, FluidBlock blk, size_t np, size_t orderOfJacobian, number EPS) {

    // 0th perturbation: rho
    mixin(computeFluxDerivativesAroundCell("gas.rho", "0", true));
    // 1st perturbation: u
    mixin(computeFluxDerivativesAroundCell("vel.refx", "1", false));
    // 2nd perturbation: v
    mixin(computeFluxDerivativesAroundCell("vel.refy", "2", false));
    // 3rd perturbation: P
    mixin(computeFluxDerivativesAroundCell("gas.p", "3", true));

    // compute Jacobian rows for perturbed cell
    foreach(cell; pcell.jacobian_cell_stencil) {
        size_t I, J; // indices in Jacobian matrix
        number integral;
        number volInv = 1.0 / cell.volume[0];
        for ( size_t ip = 0; ip < np; ++ip ) {
            I = cell.id*np + ip; // row index
            for ( size_t jp = 0; jp < np; ++jp ) {
                integral = 0.0;
                J = jp; // column index
                foreach(fi, iface; cell.iface) {
                    integral -= cell.outsign[fi] * iface.dFdU[ip][jp] * iface.area[0]; // gtl=0
                }
                number JacEntry = volInv * integral;
                aa[J] ~= JacEntry;
                ja[J] ~= I;
            }
        }
    }

    // clear the interface flux Jacobian entries
    foreach (iface; pcell.jacobian_face_stencil) {
        foreach (i; 0..iface.dFdU.length) {
            foreach (j; 0..iface.dFdU[i].length) {
                iface.dFdU[i][j] = 0.0;
            }
        }
    }
}

string computeFluxDerivativesAroundCell(string varName, string posInArray, bool includeThermoUpdate)
{
    string codeStr;
    codeStr ~= "cellSave.copy_values_from(pcell, CopyDataOption.all);";
    // ------------------ positive perturbation ------------------
    codeStr ~= "pcell.fs."~varName~" += EPS;";
    if ( includeThermoUpdate ) {
        codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(pcell.fs.gas);";
        codeStr ~= "blk.myConfig.gmodel.update_trans_coeffs(pcell.fs.gas);";
    }
    codeStr ~= "compute_flux(pcell, blk, orderOfJacobian, pcell.jacobian_cell_stencil, pcell.jacobian_face_stencil, ifaceP);"; 
    codeStr ~= "pcell.copy_values_from(cellSave, CopyDataOption.all);";
    // ------------------ compute interface flux derivatives ------------------
    codeStr ~= "foreach (i, iface; pcell.jacobian_face_stencil) {";
    codeStr ~= "iface.dFdU[0][" ~ posInArray ~ "] = ifaceP[i].F.mass.im/EPS.im;";         
    codeStr ~= "iface.dFdU[1][" ~ posInArray ~ "] = ifaceP[i].F.momentum.x.im/EPS.im;";
    codeStr ~= "iface.dFdU[2][" ~ posInArray ~ "] = ifaceP[i].F.momentum.y.im/EPS.im;";
    codeStr ~= "iface.dFdU[3][" ~ posInArray ~ "] = ifaceP[i].F.total_energy.im/EPS.im;";
    codeStr ~= "}";
    return codeStr;
}

void compute_flux(FVCell pcell, FluidBlock blk, size_t orderOfJacobian, FVCell[] cell_list, FVInterface[] iface_list, FVInterface[] ifaceP_list) {
    
    foreach(iface; iface_list) iface.F.clear_values();
    foreach(iface; ifaceP_list) iface.F.clear_values();

    if (orderOfJacobian > 1) {
        // TODO: add in missing MLP code. 
        // compute gradients for reconstruction
        foreach(c; cell_list) {
            c.gradients.compute_lsq_values(c.cell_cloud, c.ws, blk.myConfig);
            // It is more efficient to determine limiting factor here for some usg limiters.
            final switch (blk.myConfig.unstructured_limiter) {
            case UnstructuredLimiter.van_albada:
                // do nothing now
                break;
            case UnstructuredLimiter.min_mod:
                // do nothing now
                break;
            case UnstructuredLimiter.mlp:
                c.gradients.mlp_limit(c.cell_cloud, c.ws, blk.myConfig);
                break;
            case UnstructuredLimiter.barth:
                c.gradients.barth_limit(c.cell_cloud, c.ws, blk.myConfig);
                    break;
            case UnstructuredLimiter.venkat:
                c.gradients.venkat_limit(c.cell_cloud, c.ws, blk.myConfig, 0);
                break;
            } // end switch
        } // end foreach c
    } // end if interpolation_order > 1
    // Convective flux update
    foreach(iface; iface_list) {
        auto ublk = cast(UFluidBlock) blk;
        ublk.lsq.interp_both(iface, 0, ublk.Lft, ublk.Rght); // gtl assumed 0
        iface.fs.copy_average_values_from(ublk.Lft, ublk.Rght);
        compute_interface_flux(ublk.Lft, ublk.Rght, iface, ublk.myConfig, ublk.omegaz);
    }

    blk.applyPostConvFluxAction(0.0, 0, 0);
    
    // Viscous flux update
    if (GlobalConfig.viscous) {
        // currently only for least-squares at faces
        blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);
        
        foreach(iface; iface_list) {
            iface.grad.gradients_leastsq(iface.cloud_fs, iface.cloud_pos, iface.ws_grad); // blk.flow_property_spatial_derivatives(0); 
        }
        
        final switch (blk.myConfig.turbulence_model) {
        case TurbulenceModel.none:
            foreach (cell; cell_list) cell.turbulence_viscosity_zero();
            break;
        case TurbulenceModel.baldwin_lomax:
            throw new FlowSolverException("need to port baldwin_lomax_turbulence_model");
        case TurbulenceModel.spalart_allmaras:
            throw new FlowSolverException("Should implement Spalart-Allmaras some day.");
        case TurbulenceModel.k_omega:
            foreach (cell; cell_list) cell.turbulence_viscosity_k_omega();
            break;
        }
        foreach (cell; cell_list) {
            cell.turbulence_viscosity_factor(blk.myConfig.transient_mu_t_factor);
            cell.turbulence_viscosity_limit(blk.myConfig.max_mu_t_factor);
            cell.turbulence_viscosity_zero_if_not_in_zone();
        }
        foreach(iface; iface_list) {
            iface.viscous_flux_calc();
        }
        blk.applyPostDiffFluxAction(0.0, 0, 0);
    }

    // copy perturbed flux
    foreach(i, iface; iface_list) {
        ifaceP_list[i].copy_values_from(iface, CopyDataOption.all);
    }
}


void compute_design_variable_partial_derivatives(Vector3[] design_variables, ref number[] g, size_t nPrimitive, bool with_k_omega, number EPS) {
    size_t nDesignVars = design_variables.length;
    int gtl; int ftl; number objFcnEvalP; number objFcnEvalM; string varID; number dP; number P0;

    foreach (i; 0..nDesignVars) {
        foreach (myblk; localFluidBlocks) {
            ensure_directory_is_present(make_path_name!"grid"(0));
            string gridFileName = make_file_name!"grid"("ramp", myblk.id, 0, gridFileExt = "gz");
            myblk.read_new_underlying_grid(gridFileName);
            myblk.sync_vertices_from_underlying_grid(0);
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }
        
        // perturb design variable +ve
        gtl = 1; ftl = 1;
        
        // perturb design variable in complex plan
        P0 = design_variables[i].y; 
        design_variables[i].refy = P0 + EPS;
        
        // perturb grid
        gridUpdate(design_variables, 1);

        foreach (myblk; parallel(localFluidBlocks,1)) {
            foreach(j, vtx; myblk.vertices) {
                vtx.pos[0].refx = vtx.pos[1].x;
                vtx.pos[0].refy = vtx.pos[1].y;
            }
        }

        foreach (myblk; parallel(localFluidBlocks,1)) {
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
            
            //foreach ( face; myblk.faces )
            //    foreach ( j; 0..face.cloud_pos.length) writef("%d    %.16f    %.16f \n", face.id, face.ws_grad.wx[j], face.ws_grad.wy[j]); 
        }
        
        //evalRHS(0.0, ftl, 0, with_k_omega);
        steadystate_core.evalRHS(0.0, ftl);
        
        objFcnEvalP = objective_function_evaluation(0);
        
        // compute cost function sensitivity
        g[i] = (objFcnEvalP.im)/(EPS.im);
        
        // compute residual sensitivity
        foreach (myblk; parallel(localFluidBlocks,1)) {
            foreach(j, cell; myblk.cells) {
                myblk.rT[i, j*nPrimitive] = to!number((cell.dUdt[ftl].mass.im)/(EPS.im));
                myblk.rT[i, j*nPrimitive+1] = to!number((cell.dUdt[ftl].momentum.x.im)/(EPS.im));
                myblk.rT[i, j*nPrimitive+2] = to!number((cell.dUdt[ftl].momentum.y.im)/(EPS.im));
                myblk.rT[i, j*nPrimitive+3] = to!number((cell.dUdt[ftl].total_energy.im)/(EPS.im));
            }
        }
        
        // restore design variable
        design_variables[i].refy = P0;
    }
}

/**************************/
/*  OBJECTIVE FUNCTIONS   */
/**************************/
number objective_function_evaluation(int gtl=0, string bndaryForSurfaceIntergral = "objective_function_surface") {
    number ObjFcn = 0.0;    
    foreach (myblk; parallel(localFluidBlocks,1)) {
        myblk.locObjFcn = 0.0;
        foreach ( bndary; myblk.bc) {
            if ( bndary.group == bndaryForSurfaceIntergral) {
                foreach ( i, face; bndary.faces ) {
                    FVCell cell;
                    if (bndary.outsigns[i] == 1) {
                        cell = face.left_cell;
                    } else {
                        cell = face.right_cell;
                    }
                    myblk.locObjFcn += cell.fs.gas.p*face.area[gtl]; 
                }
            }
        }
    }
    foreach ( myblk; localFluidBlocks) ObjFcn += myblk.locObjFcn;
    return fabs(ObjFcn);
}

void form_objective_function_sensitivity(FluidBlock blk, size_t np, number EPS, string bndaryForSurfaceIntergral = "objective_function_surface") {

    // for now we have hard coded the pressure drag in the x-direction as the objective function
    size_t nLocalCells = blk.cells.length;
    blk.f.length = nLocalCells * np;

    foreach(cell; blk.cells) {
        for ( size_t ip = 0; ip < np; ++ip ) {
            blk.f[cell.id*np + ip] = 0.0;
        }
    }
    
    foreach (cell; blk.cells) {
        number origValue; number ObjFcnM; number ObjFcnP; number h;
        // for current objective function only perturbations in pressure have any effect
        origValue = cell.fs.gas.p;
        cell.fs.gas.p = origValue + EPS;
        ObjFcnP = objective_function_evaluation();
        blk.f[cell.id*np + 3] = (ObjFcnP.im)/(EPS.im);
        cell.fs.gas.p = origValue;
    }
    
}

/**********************************/
/*  GRID PERTURBATION FUNCTIONs   */
/**********************************/
void fit_design_parameters_to_surface(ref Vector3[] designVars)
{
    // fitting tolerances
    double tol = GlobalConfig.sscOptions.tolBezierCurveFit;
    int maxSteps = GlobalConfig.sscOptions.maxStepsBezierCurveFit;
    int nCntrlPts;
    
    // collect vertices along design surface (may cross multiple blocks)
    Vector3[] orderedList; Vector3[] unorderedList;
    size_t[string] origPosId; // used to identify where the point is in the unordered list
    number[] xPosition;
    foreach ( blk; localFluidBlocks ) {
        size_t[] idList;
        foreach ( bndary; blk.bc ) {
            if (bndary.is_design_surface) {
                nCntrlPts = bndary.num_cntrl_pts;
                foreach ( face; bndary.faces) {
                    foreach ( vtx; face.vtx) {
                        // check x-position uniqueness
                        bool uniqueXPos = true ;
                        foreach ( i; 0..unorderedList.length) {
                            number diff = abs(vtx.pos[0].x - xPosition[i]);
                            if ( diff < ESSENTIALLY_ZERO) uniqueXPos = false;
                        }
                        if (uniqueXPos) {                   
                            unorderedList ~= Vector3(vtx.pos[0].x, vtx.pos[0].y, vtx.pos[0].z);
                            xPosition ~= vtx.pos[0].x;
                            string xPosIdx = to!string(vtx.pos[0].x);
                            origPosId[xPosIdx] = unorderedList.length-1;
                        }
                    }
                }
            }
        }
    }

    // order points in ascending x-position (WARNING: it is assumed that, for a given design surface boundary, each x-coordinate is unique).
    xPosition.sort();
    foreach(x; xPosition) orderedList ~= unorderedList[origPosId[to!string(x)]];

    double[] ts;
    Bezier bezier = optimiseBezierPoints(orderedList, nCntrlPts, ts, tol, maxSteps);
    // first and last control points are not design variables
    foreach ( i; 1..bezier.B.length-1) {
        designVars ~= bezier.B[i];
    }

    // transmit global bezier to all relevant blocks
    // copy bezier curve object to each design surface boundary, along with relevant portion of the ts array
    foreach (myblk; parallel(localFluidBlocks,1)) {
        foreach (bndary; myblk.bc) {
            if (bndary.is_design_surface) {
                bndary.bezier = bezier;
                number xi = bndary.faces[0].vtx[0].pos[0].x;
                number xf = bndary.faces[0].vtx[0].pos[0].x;
                foreach ( face; bndary.faces ) {
                    foreach ( vtx; face.vtx ) {
                        if (vtx.pos[0].x < xi) xi = vtx.pos[0].x;
                        else if (vtx.pos[0].x > xf) xf = vtx.pos[0].x;
                        else continue;
                    }
                }
                size_t idxi; size_t idxf;
                foreach (i, t; ts ) {
                    if ( abs(orderedList[i].x - xi) < ESSENTIALLY_ZERO) idxi = i;
                    else if ( abs(orderedList[i].x - xf) < ESSENTIALLY_ZERO) idxf = i;
                    else {} //do nothing
                } // foreach (ts)
                bndary.ts.length = ts[idxi..idxf+1].length;
                bndary.ts[] = ts[idxi..idxf+1];
            } // end if
        } // end foreach blk.bc
    } // end foreach blk
    writeBezierDataToFile();
} // end parameterise_design_surfaces

void gridUpdate(Vector3[] designVars, size_t gtl) {
    size_t nDesignVars = designVars.length;
    
    foreach (myblk; parallel(localFluidBlocks,1)) {
        foreach(j, vtx; myblk.vertices) {
            vtx.pos[gtl].refx = vtx.pos[0].x;
            vtx.pos[gtl].refy = vtx.pos[0].y;
        }
    }

    Vector3[] bndaryVtxInitPos;
    foreach (myblk; localFluidBlocks) {
        size_t[] idList;
        foreach(bndary; myblk.bc) {
            foreach( face; bndary.faces) {
                foreach ( vtx; face.vtx) {
                    if (idList.canFind(vtx.id) == false) {
                        bndaryVtxInitPos ~= vtx.pos[0];
                        myblk.boundaryVtxIndexList ~= vtx.id;
                    }
                }
            }
        }
    }

    foreach (myblk; localFluidBlocks) {
        foreach( bndary; myblk.bc ) {
                if (bndary.is_design_surface) {
                    foreach ( i; 1..bndary.bezier.B.length-1) {
                        // y-variable
                        bndary.bezier.B[i].refy = designVars[i-1].y;
                    }
                    
                    foreach(j, vtx; bndary.vertices) {
                        //vtx.pos[gtl].refx = bndary.bezier(bndary.ts[j]).x;
                        //vtx.pos[gtl].refy = bndary.bezier(bndary.ts[j]).y;
                        version(complex_numbers) vtx.pos[gtl].refx = complex(vtx.pos[gtl].x.re, bndary.bezier(bndary.ts[j]).x.im);
                        version(complex_numbers) vtx.pos[gtl].refy = complex(vtx.pos[gtl].y.re, bndary.bezier(bndary.ts[j]).y.im);
                    }
                }
        }
    }
    
    Vector3[] bndaryVtxNewPos;
    foreach (myblk; localFluidBlocks) {
        size_t[] idList;
        foreach(bndary; myblk.bc) {
            foreach( face; bndary.faces) {
                foreach ( vtx; face.vtx) {
                    if (idList.canFind(vtx.id) == false) {
                        bndaryVtxNewPos ~= vtx.pos[gtl];
                    }
                }
            }
        }
    }
    
    foreach (myblk; localFluidBlocks) {
        inverse_distance_weighting(myblk, bndaryVtxInitPos, bndaryVtxNewPos, gtl);
    }

    foreach (myblk; localFluidBlocks) {
        myblk.boundaryVtxIndexList = [];
    }
}

void collect_boundary_vertices(FluidBlock blk)
{
    // make a block local collection of the vertices along domain boundaries
    foreach (bndary; blk.bc) {
        if ( bndary.type != "exchange_using_mapped_cells") {
            if (bndary.is_design_surface) { // we need to order the vertices by x-position
                FVVertex[] vtxOrdered; FVVertex[] vtxUnordered;
                size_t[string] origPosId; // used to identify where the point is in the unordered list
                number[] xPosition; size_t[] listOfAddedVtxIds;
                foreach(face; bndary.faces) {
                    foreach(vtx; face.vtx) {
                        if (!listOfAddedVtxIds.canFind(vtx.id)) {
                            blk.boundaryVtxIndexList ~= vtx.id;
                            vtxUnordered ~= vtx;
                            xPosition ~= vtx.pos[0].x;
                            listOfAddedVtxIds ~= vtx.id;
                            string xPosIdx = to!string(vtx.pos[0].x);
                            origPosId[xPosIdx] = vtxUnordered.length-1;
                        } // end if
                    } // foreach vtx
                } // end foreach face
                
                // order points in ascending x-position (WARNING: it is assumed that, for a given design surface boundary, each x-coordinate is unique).
                xPosition.sort();
                foreach(x; xPosition) vtxOrdered ~= vtxUnordered[origPosId[to!string(x)]];
                bndary.vertices ~= vtxOrdered;
            } else { // we don't need the vertices in any particular order
                size_t[] listOfAddedVtxIds;
                foreach(face; bndary.faces) {
                    foreach(vtx; face.vtx) {
                        if (!listOfAddedVtxIds.canFind(vtx.id)) {
                            bndary.vertices ~= vtx;
                            listOfAddedVtxIds ~= vtx.id;
                            blk.boundaryVtxIndexList ~= vtx.id;
                        } // end if
                    } // end foreach vtx
                } // end foreach face
            } // end else
        } // end if
    } // end foreach bndary
} // end collect_boundary_vertices


/*************************/
/*  EVALUATE RHS @ gtl   */
/*************************/
void evalRHS(double pseudoSimTime, int ftl, int gtl, bool with_k_omega)
{
    foreach (blk; parallel(localFluidBlocks,1)) {
        blk.clear_fluxes_of_conserved_quantities();
        foreach (cell; blk.cells) cell.clear_source_vector();
    }
    
    exchange_ghost_cell_boundary_data(pseudoSimTime, gtl, ftl);
    
    foreach (blk; localFluidBlocks) {
        blk.applyPreReconAction(pseudoSimTime, gtl, ftl);
    }
    
    // We don't want to switch between flux calculator application while
    // doing the Frechet derivative, so we'll only search for shock points
    // at ftl = 0, which is when the F(U) evaluation is made.
    if ( ftl == 0 && (GlobalConfig.flux_calculator == FluxCalculator.adaptive_efm_ausmdv ||
		      GlobalConfig.flux_calculator == FluxCalculator.adaptive_hlle_ausmdv)) {
        foreach (blk; parallel(localFluidBlocks,1)) {
            blk.detect_shock_points();
        }
    }

     foreach (blk; parallel(localFluidBlocks,1)) {
        blk.convective_flux_phase0(gtl);
    }
    foreach (blk; parallel(localFluidBlocks,1)) {
        blk.convective_flux_phase1(gtl);
    }
    foreach (blk; localFluidBlocks) {
        blk.applyPostConvFluxAction(pseudoSimTime, gtl, ftl);
    }
    if (GlobalConfig.viscous) {
        foreach (blk; localFluidBlocks) {
            blk.applyPreSpatialDerivActionAtBndryFaces(pseudoSimTime, gtl, ftl);
        }
        foreach (blk; parallel(localFluidBlocks,1)) {
            blk.flow_property_spatial_derivatives(gtl); 
            blk.estimate_turbulence_viscosity();
            blk.viscous_flux();
        }
        foreach (blk; localFluidBlocks) {
            blk.applyPostDiffFluxAction(pseudoSimTime, gtl, ftl);
        }
    }

    foreach (blk; parallel(localFluidBlocks,1)) {
        bool local_with_k_omega = with_k_omega;
        foreach (i, cell; blk.cells) {
            cell.add_inviscid_source_vector(gtl, 0.0);
            if (blk.myConfig.viscous) {
                cell.add_viscous_source_vector(local_with_k_omega);
            }
            if (blk.myConfig.udf_source_terms) {
                addUDFSourceTermsToCell(blk.myL, cell, gtl, 
                                        pseudoSimTime, blk.myConfig.gmodel);
            }
            cell.time_derivatives(gtl, ftl, local_with_k_omega);
        }
    }
}


/**********************/
/*  GMRES FUNCTIONS   */
/**********************/
string dot_over_blocks(string dot, string A, string B)
{
    return `
foreach (blk; parallel(localFluidBlocks,1)) {
   blk.dotAcc = 0.0;
   foreach (k; 0 .. blk.nvars) {
      blk.dotAcc += blk.`~A~`[k].re*blk.`~B~`[k].re;
   }
}
`~dot~` = 0.0;
foreach (blk; localFluidBlocks) `~dot~` += blk.dotAcc;`;

}

string norm2_over_blocks(string norm2, string blkMember)
{
    return `
foreach (blk; parallel(localFluidBlocks,1)) {
   blk.normAcc = 0.0;
   foreach (k; 0 .. blk.nvars) {
      blk.normAcc += blk.`~blkMember~`[k].re*blk.`~blkMember~`[k].re;
   }
}
`~norm2~` = 0.0;
foreach (blk; localFluidBlocks) `~norm2~` += blk.normAcc;
`~norm2~` = sqrt(`~norm2~`);`;

}

void rpcGMRES_solve(size_t nPrimitive) {    
    // restarted-GMRES settings
    size_t maxIters = GlobalConfig.sscOptions.gmresRestartInterval; // maxOuterIters
    size_t m = maxIters;
    number outerTol = GlobalConfig.sscOptions.stopOnRelativeGlobalResidual;
    size_t maxRestarts = 1000;
    size_t iterCount;
    number resid;
    size_t nRestarts;
    size_t r;
    // allocate GMRES arrays attached to the block objectcs
    foreach (blk; localFluidBlocks) {
        size_t n = nPrimitive*blk.cells.length;
        blk.nvars = n;
        // Now allocate arrays and matrices
        blk.psi.length = n;
        blk.r0.length = n;
        blk.x0.length = n;
        blk.v.length = n;
        blk.w.length = n;
        blk.wext.length = n;
        blk.z.length = n;
        blk.V = new Matrix!number(n, m+1);
        blk.Q1 = new Matrix!number(m+1, m+1);
        blk.g0.length = m+1;
        blk.g1.length = m+1;
    }    

    // allocate global GMRES arrays
    g0.length = m+1;
    g1.length = m+1;
    h.length = m+1;
    hR.length = m+1;
    H0 = new Matrix!number(m+1, m);
    H1 = new Matrix!number(m+1, m);
    Gamma = new Matrix!number(m+1, m+1);
    Q0 = new Matrix!number(m+1, m+1);
    Q1 = new Matrix!number(m+1, m+1);
    
    // Initialise some global arrays and matrices that have already been allocated
    g0[] = to!number(0.0);
    g1[] = to!number(0.0);
    H0.zeros();
    H1.zeros();

    number[] Z; // global array used in the matrix-vector product
    
    // 1. Evaluate r0, beta, v1
    // r0 = b - A*x0
    foreach (blk; parallel(localFluidBlocks,1)) {
        blk.x0[] = to!number(1.0); 
    }

    // parallel matrix-vector product; Saad, Krylov Subspace Methods in Distributed Computing Environments
    // 1. exchange interface data
    // let's take a shortcut for now by grabbing the global z array, this won't work for MPI
    Z = [];                        
    foreach (blk; localFluidBlocks) {
        Z ~= blk.x0[];
    }
    foreach (blk; localFluidBlocks) {
        blk.Z.length = Z.length;
        blk.Z[] = Z[];
    }
    // 2. local product
    foreach (blk; parallel(localFluidBlocks,1)) {
        multiply(blk.JlocT, blk.x0, blk.r0);
    }
    foreach (blk; parallel(localFluidBlocks,1)) {
        foreach (k; 0 .. blk.nvars) { blk.r0[k] = blk.f[k] - blk.r0[k];}
    }
    
    // Then compute v = r0/||r0||
    number betaTmp;
    mixin(norm2_over_blocks("betaTmp", "r0"));
    number beta = betaTmp;
    g0[0] = beta;
    foreach (blk; parallel(localFluidBlocks,1)) {
        foreach (k; 0 .. blk.nvars) {
            blk.v[k] = blk.r0[k]/beta;
            blk.V[k,0] = blk.v[k];
        }
    }
    
    // Compute tolerance
    //auto outerTol = eta*beta;
    
    // 2. Start outer-loop of restarted GMRES

    for ( r = 0; r < maxRestarts; r++ ) {
        // 2a. Begin iterations
        foreach (j; 0 .. m) {
            iterCount = j+1;

            // compute z (preconditioning step);
            foreach (blk; parallel(localFluidBlocks,1)) {
                blk.z[] = blk.v[];
                solve(blk.P, blk.z);
            }

            // compute w
            // parallel matrix-vector product; Saad, Krylov Subspace Methods in Distributed Computing Environments
            // 1. exchange interface data
            // let's take a shortcut for now by grabbing the global z array, this won't work for MPI
            Z = [];                        
            foreach (blk; localFluidBlocks) {
                Z ~= blk.z[];
            }
            foreach (blk; localFluidBlocks) {
                blk.Z.length = Z.length;
                blk.Z[] = Z[];
            }
            // 2. local product
            foreach (blk; parallel(localFluidBlocks,1)) {
                multiply(blk.JlocT, blk.z, blk.w);
            }
            
            // The remainder of the algorithm looks a lot like any standard
            // GMRES implementation (for example, see smla.d)
            foreach (i; 0 .. j+1) {
                foreach (blk; parallel(localFluidBlocks,1)) {
                    // Extract column 'i'
                    foreach (k; 0 .. blk.nvars ) blk.v[k] = blk.V[k,i]; 
                }
                number H0_ij_tmp;
                mixin(dot_over_blocks("H0_ij_tmp", "w", "v"));
                number H0_ij = H0_ij_tmp;
                H0[i,j] = H0_ij;
                foreach (blk; parallel(localFluidBlocks,1)) {
                    foreach (k; 0 .. blk.nvars) blk.w[k] -= H0_ij*blk.v[k]; 
                }
            }
            number H0_jp1j_tmp;
            mixin(norm2_over_blocks("H0_jp1j_tmp", "w"));
            number H0_jp1j = H0_jp1j_tmp;
            H0[j+1,j] = H0_jp1j;
        
            foreach (blk; parallel(localFluidBlocks,1)) {
                foreach (k; 0 .. blk.nvars) {
                    blk.v[k] = blk.w[k]/H0_jp1j;
                    blk.V[k,j+1] = blk.v[k];
                }
            }

            // Build rotated Hessenberg progressively
            if ( j != 0 ) {
                // Extract final column in H
                foreach (i; 0 .. j+1) h[i] = H0[i,j];
                // Rotate column by previous rotations (stored in Q0)
                nm.bbla.dot!number(Q0, j+1, j+1, h, hR);
                // Place column back in H
                foreach (i; 0 .. j+1) H0[i,j] = hR[i];
            }
            // Now form new Gamma
            Gamma.eye();
            auto denom = sqrt(H0[j,j]*H0[j,j] + H0[j+1,j]*H0[j+1,j]);
            auto s_j = H0[j+1,j]/denom; 
            auto c_j = H0[j,j]/denom;
            Gamma[j,j] = c_j; Gamma[j,j+1] = s_j;
            Gamma[j+1,j] = -s_j; Gamma[j+1,j+1] = c_j;
            // Apply rotations
            nm.bbla.dot!number(Gamma, j+2, j+2, H0, j+1, H1);
            nm.bbla.dot!number(Gamma, j+2, j+2, g0, g1);
            // Accumulate Gamma rotations in Q.
            if ( j == 0 ) {
                copy(Gamma, Q1);
            }
            else {
                nm.bbla.dot!number(Gamma, j+2, j+2, Q0, j+2, Q1);
            }
            // Prepare for next step
            copy(H1, H0);
            g0[] = g1[];
            copy(Q1, Q0);
            // Get residual
            resid = fabs(g1[j+1]);
            // DEBUG:
            //      writefln("OUTER: restart-count= %d iteration= %d, resid= %e", r, j, resid);
            if ( resid <= outerTol ) {
                m = j+1;
                // DEBUG:
                //      writefln("OUTER: TOL ACHIEVED restart-count= %d iteration-count= %d, resid= %e", r, m, resid);
                break;
            }
        }
        
        if (iterCount == maxIters)
            m = maxIters;
        // At end H := R up to row m
        //        g := gm up to row m
        nm.bbla.upperSolve!number(H1, to!int(m), g1);
        // In serial, distribute a copy of g1 to each block
        foreach (blk; localFluidBlocks) blk.g1[] = g1[];
        foreach (blk; parallel(localFluidBlocks,1)) {
            nm.bbla.dot!number(blk.V, blk.nvars, m, blk.g1, blk.psi);
        }
        foreach (blk; parallel(localFluidBlocks,1)) {
            nm.smla.solve(blk.P, blk.psi);
        }
        foreach (blk; parallel(localFluidBlocks,1)) {
            foreach (k; 0 .. blk.nvars) blk.psi[k] += blk.x0[k];
        }
        writef("global residual: %.16e \n",  resid);
        if ( resid <= outerTol || r+1 == maxRestarts ) {
            // DEBUG:  writefln("resid= %e outerTol= %e  r+1= %d  maxRestarts= %d", resid, outerTol, r+1, maxRestarts);
            // DEBUG:  writefln("Breaking restart loop.");
            break;
        }
        writeln("RESTARTING");
        // Else, we prepare for restart by setting x0 and computing r0
        // Computation of r0 as per Fraysee etal (2005)
        foreach (blk; parallel(localFluidBlocks,1)) {
            blk.x0[] = blk.psi[];
        }
        /*
        foreach (blk; localFluidBlocks) copy(Q1, blk.Q1);
        // Set all values in g0 to 0.0 except for final (m+1) value
        foreach (i; 0 .. m) g0[i] = 0.0;
        foreach (blk; localFluidBlocks) blk.g0[] = g0[];
        
        foreach (blk; parallel(localFluidBlocks,1)) {
            nm.bbla.dot(blk.Q1, m, m+1, blk.g0, blk.g1);
        }
        foreach (blk; parallel(localFluidBlocks,1)) {
            nm.bbla.dot(blk.V, blk.nvars, m+1, blk.g1, blk.r0);
        }
        */

        // parallel matrix-vector product; Saad, Krylov Subspace Methods in Distributed Computing Environments
        // 1. exchange interface data
        // let's take a shortcut for now by grabbing the global z array, this won't work for MPI
        Z = [];                        
        foreach (blk; localFluidBlocks) {
            Z ~= blk.x0[];
        }
        foreach (blk; localFluidBlocks) {
            blk.Z.length = Z.length;
            blk.Z[] = Z[];
        }
        // 2. local product
        foreach (blk; parallel(localFluidBlocks,1)) {
            nm.smla.multiply(blk.JlocT, blk.x0, blk.r0);
        }
        foreach (blk; parallel(localFluidBlocks,1)) {
            foreach (k; 0 .. blk.nvars) { blk.r0[k] = blk.f[k] - blk.r0[k];}
        }
        mixin(norm2_over_blocks("betaTmp", "r0"));
        beta = betaTmp;
        // DEBUG: writefln("OUTER: ON RESTART beta= %e", beta);
        foreach (blk; parallel(localFluidBlocks,1)) {
            foreach (k; 0 .. blk.nvars) {
                blk.v[k] = blk.r0[k]/beta;
                blk.V[k,0] = blk.v[k];
            }
        }
        // Re-initialise some vectors and matrices for restart
        g0[] = to!number(0.0);
        g1[] = to!number(0.0);
        H0.zeros();
        H1.zeros();
        // And set first residual entry
        g0[0] = beta;

    }
    nRestarts = to!int(r);
    writeln(nRestarts, " restarts.");
}

/**********************/
/*    IO FUNCTIONS    */
/**********************/
void writeBezierDataToFile()
{
    foreach ( myblk; localFluidBlocks) {
        foreach (bndary; myblk.bc) {
            if (bndary.is_design_surface) {
                string fileName = "blk" ~ to!string(myblk.id) ~ ".bezier";
                if (exists(fileName)) {
                    string error_msg = format(".bezier files already exist. Please remove before proceeding.");
                    throw new FlowSolverException(error_msg);
                }
                auto outFile = File(fileName, "a");
                foreach ( point; bndary.bezier.B) {
                    outFile.writef("%.16e %.16e %.16e \n", point.x.re, point.y.re, point.z.re);
                }
                foreach( t; bndary.ts ) {
                    outFile.writef("%.16e \n", t);
                }
            } 
        } 
    } 
} // end writeBexierDataToFile

void readBezierDataFromFile(ref Vector3[] designVars)
{
    foreach (myblk; parallel(localFluidBlocks,1)) {
        collect_boundary_vertices(myblk);
    }

    foreach ( myblk; localFluidBlocks) {
        foreach (bndary; myblk.bc) {
            if (bndary.is_design_surface) {
                string fileName = "blk" ~ to!string(myblk.id) ~ ".bezier";
                if (!exists(fileName)) {
                    string error_msg = format(".bezier file does not exist");
                    throw new FlowSolverException(error_msg);
                }
                auto fR = File(fileName, "r");
                //while (!fR.eof) {
                Vector3[] bezPts;
                foreach ( i; 0..bndary.num_cntrl_pts) {
                    auto line = fR.readln().strip();
                    auto tokens = line.split();
                    Vector3 pt;
                    pt.refx = to!number(tokens[0]); pt.refy = to!number(tokens[1]); pt.refz = to!number(tokens[2]);
                    bezPts ~= pt;
                }
                bndary.bezier = new Bezier(bezPts);
                foreach ( i; 0..bndary.vertices.length) {
                    auto line = fR.readln().strip();
                    auto tokens = line.split();
                    bndary.ts ~= to!double(tokens[0]);
                    //}
                }
                if (designVars.length < 1) {
                    foreach ( i; 1..bndary.bezier.B.length-1) {
                        Vector3 dvar;
                        dvar.refx = bndary.bezier.B[i].x;
                        dvar.refy = bndary.bezier.B[i].y;
                        designVars ~= dvar;
                    }
                }
            } // end if
        } // end foreach bndary
    } // end foreach myblk
} // end readBezierDataFromFile

void write_adjoint_variables_to_file(FluidBlock blk, size_t np, string jobName) {
    size_t ncells = blk.cells.length;
    size_t nvertices = blk.vertices.length;
    // write out adjoint variables in VTK-format
    if (blk.grid_type == Grid_t.structured_grid) throw new FlowSolverException("Shape Sensitivity Calculator not implemented for structured grids, yet."); 
    if (blk.grid_type == Grid_t.unstructured_grid) {
        auto fileName = "adjointVars" ~ to!string(blk.id) ~ ".vtk";
        auto ublk = cast(UFluidBlock) blk; 
        auto outFile = File(fileName, "w");
        outFile.writef("# vtk DataFile Version 3.0 \n");
        outFile.writef("%s \n", jobName);
        outFile.writef("ASCII \n");
        outFile.writef("DATASET UNSTRUCTURED_GRID \n");
        outFile.writef("POINTS %d double \n", nvertices);
        // write grid data
        foreach(i, vtx; blk.vertices) {
            outFile.writef("%.16f %.16f %.16f \n", vtx.pos[0].x.re, vtx.pos[0].y.re, vtx.pos[0].z.re); 
        }
        // write cell connectivity
        size_t connections = 0;
        foreach ( cell; blk.cells) {
            connections += cell.iface.length;
        }
        size_t size = ncells + connections; // TODO: only for quads, need to generalise

        outFile.writef("CELLS %d %d \n", ncells, size);
        foreach(i, cell; ublk.grid.cells) {
            outFile.writef("%d ", cell.vtx_id_list.length);
            foreach(vid; cell.vtx_id_list) {
                outFile.writef("%d ", vid);
            }
            outFile.writef("\n");
        }
        outFile.writef("CELL_TYPES %d \n", ncells);
        foreach(i, cell; ublk.grid.cells) {
            outFile.writef("%d \n", ublk.grid.vtk_element_type_for_cell(i)); //cell.cell_type);
        }
        
        // write cell data
        outFile.writef("CELL_DATA %d \n", ncells);

        outFile.writef("SCALARS adjoint_density double \n");
        outFile.writef("LOOKUP_TABLE default \n");
        foreach(i; 0..ncells) {
            outFile.writef("%.16f \n", blk.psi[np*i].re);
        }

        outFile.writef("SCALARS adjoint_velx double \n");
        outFile.writef("LOOKUP_TABLE default \n");
        foreach(i; 0..ncells) {
            outFile.writef("%.16f \n", blk.psi[np*i+1].re);
        }

        outFile.writef("SCALARS adjoint_vely double \n");
        outFile.writef("LOOKUP_TABLE default \n");
        foreach(i; 0..ncells) {
            outFile.writef("%.16f \n", blk.psi[np*i+2].re);
        }

        outFile.writef("SCALARS adjoint_pressure double \n");
        outFile.writef("LOOKUP_TABLE default \n");
        foreach(i; 0..ncells) { 
            outFile.writef("%.16f \n", blk.psi[np*i+3].re);
        }

    }
}

/*****************************/
/*  DIRECT GRADIENT METHOD   */
/*****************************/
void compute_direct_complex_step_derivatives(string jobName, int last_tindx, int maxCPUs, Vector3[] design_variables, number EPS) {
    writeln(" ");
    writeln("------------------------------------------------------");
    writeln("----EVALUATING DERIVATIVES VIA DIRECT COMPLEX STEP----");
    writeln("------------------------------------------------------");
    writeln(" ");
        
    size_t nDesignVars = design_variables.length;
    double[] gradients; number P0; number objFcnP; number objFcnM; 

    foreach ( i; 0..nDesignVars) {
        writeln("----- Computing Gradient for variable: ", i);
        foreach (myblk; localFluidBlocks) {
            ensure_directory_is_present(make_path_name!"grid"(0));
            string gridFileName = make_file_name!"grid"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.read_new_underlying_grid(gridFileName);
            myblk.sync_vertices_from_underlying_grid(0);
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }
    
        foreach (myblk; localFluidBlocks) {
            myblk.read_solution(make_file_name!"flow"(jobName, myblk.id, 0, flowFileExt), false);

            foreach (cell; myblk.cells) {
                cell.encode_conserved(0, 0, myblk.omegaz);
                // Even though the following call appears redundant at this point,
                // fills in some gas properties such as Prandtl number that is
                // needed for both the cfd_check and the BaldwinLomax turbulence model.
                cell.decode_conserved(0, 0, myblk.omegaz);
            }
        }
        
        // perturb design variable in complex plane
        P0 = design_variables[i].y; 
        design_variables[i].refy = P0 + EPS;
        
        // perturb grid
        gridUpdate(design_variables, 1); // gtl = 1

        foreach (myblk; parallel(localFluidBlocks,1)) {
            foreach(j, vtx; myblk.vertices) {
                vtx.pos[0].refx = vtx.pos[1].x;
                vtx.pos[0].refy = vtx.pos[1].y;
            }
        }
        
        foreach (myblk; localFluidBlocks) {
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
            //foreach ( face; myblk.faces )
            //    foreach ( j; 0..face.cloud_pos.length) writef("%d    %.16f    %.16f \n", face.id, face.ws_grad.wx[j], face.ws_grad.wy[j]); 
        }

        foreach (myblk; localFluidBlocks) {
            // save mesh
            myblk.sync_vertices_to_underlying_grid(0);
            ensure_directory_is_present(make_path_name!"grid-p"(0));
            auto fileName = make_file_name!"grid-p"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.write_underlying_grid(fileName);
        }
            
        // Additional memory allocation specific to steady-state solver
        allocate_global_workspace();
        foreach (myblk; localFluidBlocks) {
            myblk.allocate_GMRES_workspace();
        }
        
        // run steady-state solver
        iterate_to_steady_state(0, maxCPUs); // snapshotStart = 0
        //GlobalConfig.report_residuals = true;
        //sim_time = 0.0;
        //integrate_in_time(GlobalConfig.max_time);
        
        // compute objective function gradient
        objFcnP = objective_function_evaluation();
        
        // return value to original state
        design_variables[i].refy = P0;
        
        // compute objective function gradient
        objFcnM = objective_function_evaluation();
        gradients ~= (objFcnP.im)/(EPS.im);
        
        // return value to original state
        design_variables[i].refy = P0;
    }
    foreach ( i; 0..nDesignVars) {
        writef("gradient for variable %d: %.16e \n", i, gradients[i]);
    }
    writeln("simulation complete.");
}

/*
void compute_direct_complex_step_derivatives(string jobName, int last_tindx, int maxCPUs, Vector3[] design_variables, number EPS) {
    writeln(" ");
    writeln("------------------------------------------------------");
    writeln("----EVALUATING DERIVATIVES VIA DIRECT COMPLEX STEP----");
    writeln("------------------------------------------------------");
    writeln(" ");
        
    size_t nDesignVars = design_variables.length;
    double[] gradients; number P0; number objFcnP; number objFcnM; 

    foreach ( i; 0..nDesignVars) {
        writeln("----- Computing Gradient for variable: ", i);
        foreach (myblk; localFluidBlocks) {
            ensure_directory_is_present(make_path_name!"grid"(0));
            string gridFileName = make_file_name!"grid"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.read_new_underlying_grid(gridFileName);
            myblk.sync_vertices_from_underlying_grid(0);
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }
    
        foreach (myblk; localFluidBlocks) {
            myblk.read_solution(make_file_name!"flow"(jobName, myblk.id, 0, flowFileExt), false);

            foreach (cell; myblk.cells) {
                cell.encode_conserved(0, 0, myblk.omegaz);
                // Even though the following call appears redundant at this point,
                // fills in some gas properties such as Prandtl number that is
                // needed for both the cfd_check and the BaldwinLomax turbulence model.
                cell.decode_conserved(0, 0, myblk.omegaz);
            }
        }
        
        // perturb design variable in complex plane
        P0 = design_variables[i].y; 
        design_variables[i].refy = P0 + EPS.im;
        
        // perturb grid
        gridUpdate(design_variables, 1); // gtl = 1

        foreach (myblk; parallel(localFluidBlocks,1)) {
            foreach(j, vtx; myblk.vertices) {
                vtx.pos[0].refx = vtx.pos[1].x;
                vtx.pos[0].refy = vtx.pos[1].y;
            }
        }
        
        foreach (myblk; localFluidBlocks) {
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }

        foreach (myblk; localFluidBlocks) {
            // save mesh
            myblk.sync_vertices_to_underlying_grid(0);
            ensure_directory_is_present(make_path_name!"grid-p"(0));
            auto fileName = make_file_name!"grid-p"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.write_underlying_grid(fileName);
        }
            
        // Additional memory allocation specific to steady-state solver
        allocate_global_workspace();
        foreach (myblk; localFluidBlocks) {
            myblk.allocate_GMRES_workspace();
        }
        
        // run steady-state solver
        iterate_to_steady_state(0, maxCPUs); // snapshotStart = 0
        //GlobalConfig.report_residuals = true;
        //sim_time = 0.0;
        //integrate_in_time(GlobalConfig.max_time);
        
        // compute objective function gradient
        objFcnP = objective_function_evaluation();
                
        // return value to original state
        design_variables[i].refy = P0;


        foreach (myblk; localFluidBlocks) {
            ensure_directory_is_present(make_path_name!"grid"(0));
            string gridFileName = make_file_name!"grid"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.read_new_underlying_grid(gridFileName);
            myblk.sync_vertices_from_underlying_grid(0);
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }
    
        foreach (myblk; localFluidBlocks) {
            myblk.read_solution(make_file_name!"flow"(jobName, myblk.id, 0, flowFileExt), false);

            foreach (cell; myblk.cells) {
                cell.encode_conserved(0, 0, myblk.omegaz);
                // Even though the following call appears redundant at this point,
                // fills in some gas properties such as Prandtl number that is
                // needed for both the cfd_check and the BaldwinLomax turbulence model.
                cell.decode_conserved(0, 0, myblk.omegaz);
            }
        }
        
        // perturb design variable in complex plane
        P0 = design_variables[i].y; 
        design_variables[i].refy = P0 - EPS.im;
        
        // perturb grid
        gridUpdate(design_variables, 1); // gtl = 1

        foreach (myblk; parallel(localFluidBlocks,1)) {
            foreach(j, vtx; myblk.vertices) {
                vtx.pos[0].refx = vtx.pos[1].x;
                vtx.pos[0].refy = vtx.pos[1].y;
            }
        }
        
        foreach (myblk; localFluidBlocks) {
            myblk.compute_primary_cell_geometric_data(0);
            myblk.compute_least_squares_setup(0);
        }

        foreach (myblk; localFluidBlocks) {
            // save mesh
            myblk.sync_vertices_to_underlying_grid(0);
            ensure_directory_is_present(make_path_name!"grid-p"(0));
            auto fileName = make_file_name!"grid-p"(jobName, myblk.id, 0, gridFileExt = "gz");
            myblk.write_underlying_grid(fileName);
        }
        
        // run steady-state solver
        iterate_to_steady_state(0, maxCPUs); // snapshotStart = 0
        //GlobalConfig.report_residuals = true;
        //sim_time = 0.0;
        //integrate_in_time(GlobalConfig.max_time);
        
        // compute objective function gradient
        objFcnM = objective_function_evaluation();
        gradients ~= (objFcnP.re-objFcnM.re)/(2.0*EPS.im);
        
        // return value to original state
        design_variables[i].refy = P0;
    }
    foreach ( i; 0..nDesignVars) {
        writef("gradient for variable %d: %.16e \n", i, gradients[i]);
    }
    writeln("simulation complete.");
}
*/
/*****************************************/
/*  STEADY-STATE SOLVER PRECONDITIONER   */
/*****************************************/
void sss_preconditioner_initialisation(FluidBlock blk, size_t nConservative) {
    /*
    if (blk.grid_type == Grid_t.structured_grid) {
        auto sblk = cast(SFluidBlock) blk;
        foreach (cell; blk.cells) {
            cell.jacobian_cell_stencil ~= cell;
            size_t[3] ijk = sblk.cell_id_to_ijk_indices(cell.id);
            size_t i = ijk[0]; size_t j = ijk[1]; size_t k = ijk[2]; 
            // assume list of faces is in order: [i, i+1, j, j+1]
            cell.jacobian_face_stencil ~= sblk.get_ifi(i, j, k);
            cell.jacobian_face_stencil ~= sblk.get_ifi(i+1, j, k);
            cell.jacobian_face_stencil ~= sblk.get_ifj(i, j, k);
            cell.jacobian_face_stencil ~= sblk.get_ifj(i, j+1, k);
        }
    }
    else { // unstructured_grid
        foreach (cell; blk.cells) {
            cell.jacobian_cell_stencil ~= cell;
            foreach ( face; cell.iface) cell.jacobian_face_stencil ~= face;
        }
    }
    // initialise objects
    blk.transform = new Matrix!number(nConservative, nConservative);
    foreach (cell; blk.cells) {
        cell.dPrimitive = new Matrix!number(nConservative, nConservative);
        cell.dConservative = new Matrix!number(nConservative, nConservative);
        cell.pivot.length = nConservative;
    }
    cellSave = new FVCell(blk.myConfig);
    foreach (i; 0..MAX_PERTURBED_INTERFACES) {
        ifaceP[i] = new FVInterface(blk.myConfig, false);
    }
    */
}

void jacobian_bndary_correction_for_sss_preconditioner(FluidBlock blk, size_t np, int orderOfJacobian) {
    /*    
    number[][] dRdq; number[][] dqdQ; number[][] Lext; number[] qP;
    qP.length = np;
    dRdq.length = np; // number of conserved variables
    dqdQ.length = np; // number of conserved variables
    Lext.length = np; // number of conserved variables
    foreach (ref a; dRdq) a.length = np;
    foreach (ref a; dqdQ) a.length = np;
    foreach (ref a; Lext) a.length = np;
    foreach (i; 0..np) {
        foreach (j; 0..np) {
            dRdq[i][j] = 0.0;
            dqdQ[i][j] = 0.0;
            Lext[i][j] = 0.0;
        }
    }

    foreach ( bndary; blk.bc) {
        if (bndary.type != "exchange_using_mapped_cells") {
            foreach ( fj,f; bndary.faces) {
                
                // collect int and ext cells
                FVCell int_cell;
                FVCell pcell;
                if (bndary.outsigns[fj] == 1) {
                    int_cell = f.left_cell;
                    pcell = f.right_cell;
                } else {
                    int_cell = f.right_cell;
                    pcell = f.left_cell;
                }
                
                // form dqdQ
                // 0th perturbation: rho
                mixin(computeGhostCellDerivatives("gas.rho", "0", true));
                // 1st perturbation: u
                mixin(computeGhostCellDerivatives("vel.refx", "1", false));
                // 2nd perturbation: v
                mixin(computeGhostCellDerivatives("vel.refy", "2", false));
                // 3rd perturbation: P
                mixin(computeGhostCellDerivatives("gas.p", "3", true));
                
                // form dRdq
                pcell.jacobian_cell_stencil ~= int_cell;
                foreach ( face; int_cell.iface) pcell.jacobian_face_stencil ~= face;
                // 0th perturbation: rho
                mixin(computeFluxDerivativesAroundCell("gas.rho", "0", true));
                // 1st perturbation: u
                mixin(computeFluxDerivativesAroundCell("vel.refx", "1", false));
                // 2nd perturbation: v
                mixin(computeFluxDerivativesAroundCell("vel.refy", "2", false));
                // 3rd perturbation: P
                mixin(computeFluxDerivativesAroundCell("gas.p", "3", true));
                
                number integral;
                number volInv = 1.0 / int_cell.volume[0];
                for ( size_t ip = 0; ip < np; ++ip ) {
                    for ( size_t jp = 0; jp < np; ++jp ) {
                    integral = 0.0;
                    foreach(fi, iface; int_cell.iface) {
                        integral -= int_cell.outsign[fi] * iface.dFdU[ip][jp] * iface.area[0]; // gtl=0
                    }
                    number entry = volInv * integral;                    
                    dRdq[ip][jp] = entry;
                    }
                }
                
                // perform matrix-matrix multiplication
                for (size_t i = 0; i < np; i++) {
                    for (size_t j = 0; j < np; j++) {
                        Lext[i][j] = 0;
                        for (size_t k = 0; k < np; k++) {
                            Lext[i][j] += dRdq[i][k]*dqdQ[k][j];
                        }
                    }
                }

                // add correction to boundary entry in Jacobian
                size_t I, J;
                for ( size_t ip = 0; ip < np; ++ip ) {
                    I = int_cell.id*np + ip; // column index
                    for ( size_t jp = 0; jp < np; ++jp ) {
                        J = int_cell.id*np + jp; // column index
                        int_cell.dPrimitive[ip,jp] = int_cell.dPrimitive[ip,jp] + Lext[ip][jp];
                    }
                }
                
                // clear the interface flux Jacobian entries
                foreach (iface; pcell.jacobian_face_stencil) {
                    foreach (i; 0..iface.dFdU.length) {
                        foreach (j; 0..iface.dFdU[i].length) {
                            iface.dFdU[i][j] = 0.0;
                        }
                    }
                }
                
                // clear working matrices
                foreach (i; 0..np) {
                    foreach (j; 0..np) {
                        dRdq[i][j] = 0.0;
                        dqdQ[i][j] = 0.0;
                        Lext[i][j] = 0.0;
                    }
                }
                pcell.jacobian_cell_stencil = [];
                pcell.jacobian_face_stencil = [];
            }
        }
    }
    // reset interpolation order to the global setting
    blk.myConfig.interpolation_order = GlobalConfig.interpolation_order;
    */
}

void sss_preconditioner(FluidBlock blk, size_t np, double dt, double EPSILON, double MU, int orderOfJacobian=1) {
    /*
    // temporarily switch the interpolation order of the config object to that of the Jacobian 
    blk.myConfig.interpolation_order = orderOfJacobian;

    // initialise some variables used in the finite difference perturbation
    number h; number diff;
    
    // compute diagonal of 1st order Jacobian (w.r.t. primitive variables)
    foreach(pcell; blk.cells) {
        // 0th perturbation: rho
        mixin(computeFluxDerivativesAroundCell("gas.rho", "0", true));
        // 1st perturbation: u
        mixin(computeFluxDerivativesAroundCell("vel.refx", "1", false));
        // 2nd perturbation: v
        mixin(computeFluxDerivativesAroundCell("vel.refy", "2", false));
        // 3rd perturbation: P
        mixin(computeFluxDerivativesAroundCell("gas.p", "3", true));
        
        number integral;
        number volInv = 1.0 / pcell.volume[0];
        for ( size_t ip = 0; ip < np; ++ip ) {
            for ( size_t jp = 0; jp < np; ++jp ) {
                integral = 0.0;
                foreach(fi, iface; pcell.iface) {
                    integral -= pcell.outsign[fi] * iface.dFdU[ip][jp] * iface.area[0]; // gtl=0
                }
                number entry = volInv * integral;                    
                pcell.dPrimitive[ip,jp] = entry;
            }
        }
        // clear the interface flux Jacobian entries
        foreach (iface; pcell.jacobian_face_stencil) {
            foreach (i; 0..iface.dFdU.length) {
                foreach (j; 0..iface.dFdU[i].length) {
                    iface.dFdU[i][j] = 0.0;
                }
            }
        }
    }

    // boundary correction
    jacobian_bndary_correction_for_sss_preconditioner(blk, np, orderOfJacobian);
    auto gmodel = blk.myConfig.gmodel;
    // multiply by transform matrix (transforming primitive to conservative form)
    foreach (cell; blk.cells) {
        // form transformation matrix (TODO: genearlise, currently only for 2D Euler/Laminar Navier-Stokes).
        number gamma = gmodel.gamma(cell.fs.gas);
        // first row
        blk.transform[0,0] = to!number(1.0);
        blk.transform[0,1] = to!number(0.0);
        blk.transform[0,2] = to!number(0.0);
        blk.transform[0,3] = to!number(0.0);
        // second row
        blk.transform[1,0] = -cell.fs.vel.x/cell.fs.gas.rho;
        blk.transform[1,1] = 1.0/cell.fs.gas.rho;
        blk.transform[1,2] = to!number(0.0);
        blk.transform[1,3] = to!number(0.0);
        // third row
        blk.transform[2,0] = -cell.fs.vel.y/cell.fs.gas.rho;
        blk.transform[2,1] = to!number(0.0);
        blk.transform[2,2] = 1.0/cell.fs.gas.rho;
        blk.transform[2,3] = to!number(0.0);
        // fourth row
        blk.transform[3,0] = 0.5*(gamma-1.0)*(cell.fs.vel.x*cell.fs.vel.x+cell.fs.vel.y*cell.fs.vel.y);
        blk.transform[3,1] = -cell.fs.vel.x*(gamma-1);
        blk.transform[3,2] = -cell.fs.vel.y*(gamma-1);
        blk.transform[3,3] = gamma-1.0;

        
        nm.bbla.dot!number(cell.dPrimitive, blk.transform, cell.dConservative);

        number dtInv = 1.0/dt;
        foreach (i; 0 .. np) {
            cell.dConservative[i,i] += dtInv;
        }

        // Get an LU decomposition ready for repeated solves.
        nm.bbla.LUDecomp!number(cell.dConservative, cell.pivot);
    }
    
    // reset interpolation order to the global setting
    blk.myConfig.interpolation_order = GlobalConfig.interpolation_order;
    */
}
