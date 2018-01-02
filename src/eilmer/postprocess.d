/** postprocess.d
 * Eilmer4 compressible-flow simulation code, postprocessing functions.
 *
 * The role of the post-processing functions is just to pick up data
 * from a previously-run simulation and either write plotting files
 * or extract interesting pieces of data.
 *
 * Author: Peter J. and Rowan G. 
 * First code: 2015-06-09
 */

module postprocess;

import std.math;
import std.stdio;
import std.conv;
import std.format;
import std.string;
import std.regex;
import std.algorithm;
import std.bitmanip;
import std.stdint;
import std.range;
import gzip;
import fvcore;
import fileutil;
import geom;
import gas;
import globalconfig;
import flowsolution;
import solidsolution;
version(with_tecplot_binary) {
import tecplot_writer;
}

void post_process(string plotDir, bool listInfoFlag, string tindxPlot,
                  string addVarsStr, string luaRefSoln,
                  bool vtkxmlFlag, bool binary_format, bool tecplotBinaryFlag, bool tecplotAsciiFlag,
                  string outputFileName, string sliceListStr,
                  string surfaceListStr, string extractStreamStr,
                  string extractLineStr, string computeLoadsOnGroupStr,
                  string probeStr, string outputFormat,
                  string normsStr, string regionStr,
                  string extractSolidLineStr)
{
    read_config_file();
    string jobName = GlobalConfig.base_file_name;
    //
    string[] addVarsList;
    addVarsStr = addVarsStr.strip();
    addVarsStr = addVarsStr.replaceAll(regex("\""), "");
    if (addVarsStr.length > 0) {
        addVarsList = addVarsStr.split(",");
    }
    //
    auto times_dict = readTimesFile(jobName);
    auto tindx_list = times_dict.keys;
    sort(tindx_list);
    int[] tindx_list_to_plot;
    switch (tindxPlot) {
    case "all":
        tindx_list_to_plot = tindx_list.dup;
        break;
    case "9999":
    case "last":
        tindx_list_to_plot ~= tindx_list[$-1];
        break;
    default:
        // We assume that the command-line argument was an integer.
        tindx_list_to_plot ~= to!int(tindxPlot);
    } // end switch
    //
    if (listInfoFlag) {
        writeln("Some information about this simulation.");
        writeln("  nFluidBlocks= ", GlobalConfig.nFluidBlocks);
        writeln("  nSolidBlocks= ", GlobalConfig.nSolidBlocks);
        writeln("  last tindx= ", tindx_list[$-1]);
        writeln("  Flow Variables:");
        // Dip into the top of a solution file that is likely to be present
        // to get the variable names, as saved by the simulation.
        double sim_time;
        switch (GlobalConfig.flow_format) {
        case "gziptext": goto default;
        case "rawbinary": throw new Error("not yet implemented PJ 2017-09-02");
        default:
            string fileName = make_file_name!"flow"(jobName, to!int(0), 0, "gz");
            auto byLine = new GzipByLine(fileName);
            auto line = byLine.front; byLine.popFront();
            formattedRead(line, " %g", &sim_time);
            line = byLine.front; byLine.popFront();
            auto variableNames = line.strip().split();
            foreach (ref var; variableNames) { var = var.replaceAll(regex("\""), ""); }
            foreach (i; 0 .. variableNames.length) {
                writeln(format("%4d %s", i, variableNames[i]));
            }
        } // end switch flow_format
        if ( GlobalConfig.nSolidBlocks > 0 ) {
            writeln("  Solid Variables:");
            // Dip into the top of a solid solution file that is
            // likely to be present to get the variable names
            // as saved by the simulation.
            string fileName = make_file_name!"solid"(jobName, 0, 0, "gz");
            auto byLine = new GzipByLine(fileName);
            auto line = byLine.front; byLine.popFront();
            formattedRead(line, " %g", &sim_time);
            line = byLine.front; byLine.popFront();
            auto variableNames = line.strip().split();
            foreach (ref var; variableNames) { var = var.replaceAll(regex("\""), ""); }
            foreach (i; 0 .. variableNames.length) {
                writeln(format("%4d %s", i, variableNames[i]));
            }
        } // end if nSolidBlocks > 0
    } // end if listInfoFlag
    //
    if (vtkxmlFlag) {
        ensure_directory_is_present(plotDir);
        //
        writeln("writing flow-solution VTK-XML files to directory \"", plotDir, "\"");
        File visitFile = File(plotDir~"/"~jobName~".visit", "w");
        // For each time index, the visit justs lists the names of the files for individual blocks.
        visitFile.writef("!NBLOCKS %d\n", GlobalConfig.nFluidBlocks);
        File pvdFile = begin_PVD_file(plotDir~"/"~jobName~".pvd");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            string pvtuFileName = jobName~format("-t%04d", tindx)~".pvtu";
            add_time_stamp_to_PVD_file(pvdFile, soln.sim_time, pvtuFileName);
            File pvtuFile = begin_PVTU_file(plotDir~"/"~pvtuFileName, soln.flowBlocks[0].variableNames);
            foreach (jb; 0 .. soln.nBlocks) {
                string vtuFileName = jobName~format("-b%04d-t%04d.vtu", jb, tindx);
                add_piece_to_PVTU_file(pvtuFile, vtuFileName);
                visitFile.writef("%s\n", vtuFileName);
                write_VTU_file(soln.flowBlocks[jb], soln.gridBlocks[jb], plotDir~"/"~vtuFileName, binary_format);
            }
            finish_PVTU_file(pvtuFile);
        } // foreach tindx
        finish_PVD_file(pvdFile);
        visitFile.close();
        //
        if ( GlobalConfig.nSolidBlocks > 0 ) {
            writeln("writing solid VTK-XML files to directory \"", plotDir, "\"");
            visitFile = File(plotDir~"/"~jobName~"-solid.visit", "w");
            // For each time index, the visit justs lists the names of the files for individual blocks.
            visitFile.writef("!NBLOCKS %d\n", GlobalConfig.nSolidBlocks);
            pvdFile = begin_PVD_file(plotDir~"/"~jobName~"-solid.pvd");
            foreach (tindx; tindx_list_to_plot) {
                writeln("  tindx= ", tindx);
                auto soln = new SolidSolution(jobName, ".", tindx, GlobalConfig.nSolidBlocks);
                if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
                string pvtuFileName = jobName~format("-solid-t%04d", tindx)~".pvtu";
                add_time_stamp_to_PVD_file(pvdFile, soln.sim_time, pvtuFileName);
                File pvtuFile = begin_PVTU_file(plotDir~"/"~pvtuFileName, soln.solidBlocks[0].variableNames, false);
                foreach (jb; 0 .. soln.nBlocks) {
                    string vtuFileName = jobName~format("-solid-b%04d-t%04d.vtu", jb, tindx);
                    add_piece_to_PVTU_file(pvtuFile, vtuFileName);
                    visitFile.writef("%s\n", vtuFileName);
                    write_VTU_file(soln.solidBlocks[jb], soln.gridBlocks[jb], plotDir~"/"~vtuFileName, binary_format);
                }
                finish_PVTU_file(pvtuFile);
            } // foreach tindx
            finish_PVD_file(pvdFile);
            visitFile.close();
        } // end if nSolidBlocks > 0
    } // end if vtkxml
    //
    version(with_tecplot_binary) {
    if (tecplotBinaryFlag) {
        ensure_directory_is_present(plotDir);
        writeln("Writing Tecplot (binary) file(s) to directory \"", plotDir, "\"");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            double timeStamp = times_dict[tindx];
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            string fname = format("%s/%s.t%04d", plotDir, jobName, tindx);
            if ( writeTecplotBinaryHeader(jobName, tindx, fname, soln.flowBlocks[0].variableNames) != 0 ) {
                string errMsg = format("Tecplot binary output failed for tindx: %d", tindx);
                throw new FlowSolverException(errMsg);
            }
            foreach (jb; 0 .. GlobalConfig.nFluidBlocks) {
                int zoneType;
                size_t[][] connList;
                prepareGridConnectivity(soln.gridBlocks[jb], zoneType, connList);
                if ( writeTecplotBinaryZoneHeader(soln.flowBlocks[jb], soln.gridBlocks[jb], jb,
                                                  soln.flowBlocks[jb].variableNames, timeStamp, zoneType) != 0 ) {
                    string errMsg = format("Tecplot binary output failed for block: %d", jb);
                    throw new FlowSolverException(errMsg);
                }
                writeTecplotBinaryZoneData(soln.flowBlocks[jb], soln.gridBlocks[jb], 
                                           soln.flowBlocks[jb].variableNames, connList);
            }
            if ( closeTecplotBinaryFile() != 0 ) {
                string errMsg = format("Closing of Tecplot binary file failed for tindx: %d", tindx);
                throw new FlowSolverException(errMsg);
            }
        }
    }
    }
    else {
    if (tecplotBinaryFlag) {
        string errMsg = "This version of e4shared was NOT compiled with support for Tecplot binary files.";
        throw new FlowSolverException(errMsg);
    }   
    } 
    if (tecplotAsciiFlag) {
        writeln("writing Tecplot file(s) to directory \"", plotDir, "\"");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            // Temporary check for unstructured grids. Remove when unstructured version is implemented.
            foreach ( grid; soln.gridBlocks ) {
                if ( grid.grid_type == Grid_t.unstructured_grid ) {
                    throw new FlowSolverException("Tecplot output not currently available for unstructured grids.");
                }
            }
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            auto t = times_dict[tindx];
            write_Tecplot_file(jobName, plotDir, soln, tindx);
        } // foreach tindx
        if ( GlobalConfig.nSolidBlocks > 0 ) {
            throw new FlowSolverException("Tecplot output not currently available for solid blocks.");
        //     writeln("writing solid Tecplot file(s) to directory \"", plotDir, "\"");
        //     foreach (tindx; tindx_list_to_plot) {
        //      writeln("  tindx= ", tindx);
        //      auto soln = new SolidSolution(jobName, ".", tindx, GlobalConfig.nSolidBlocks);
        //      if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
        //      write_Tecplot_file(jobName, plotDir, soln, tindx);
        //     } // foreach tindx
        } // end if nSolidBlocks > 0
    } // end if tecplot
    //
    if (probeStr.length > 0) {
        writeln("Probing flow solution at specified points.");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        probeStr = probeStr.strip();
        probeStr = probeStr.replaceAll(regex("\""), "");
        double[] xp, yp, zp;
        foreach(triple; probeStr.split(";")) {
            auto items = triple.split(",");
            xp ~= to!double(items[0]);
            yp ~= to!double(items[1]);
            zp ~= to!double(items[2]);
        }
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            if (outputFormat == "gnuplot") {
                outFile.writeln(soln.flowBlocks[0].variable_names_as_string(true));
            }
            foreach (ip; 0 .. xp.length) {
                auto nearest = soln.find_nearest_cell_centre(xp[ip], yp[ip], zp[ip]);
                size_t ib = nearest[0]; size_t i = nearest[1];
                if (outputFormat == "gnuplot") {
                    outFile.writeln(soln.flowBlocks[ib].values_as_string(i));
                } else {
                    // Assume that pretty format was requested.
                    outFile.writefln("Block[%d], cell[%d]:", ib, i);
                    outFile.writefln("  pos=(%s, %s, %s)m, volume=%s m^^3",
                                     soln.get_value_str(ib, i, "pos.x"), soln.get_value_str(ib, i, "pos.y"),
                                     soln.get_value_str(ib, i, "pos.z"), soln.get_value_str(ib, i, "volume"));
                    outFile.writefln("  pos=(%s, %s, %s)m, volume=%s m^^3",
                                     soln.get_value_str(ib, i, "pos.x"), soln.get_value_str(ib, i, "pos.y"),
                                     soln.get_value_str(ib, i, "pos.z"), soln.get_value_str(ib, i, "volume"));
                    outFile.writefln("  rho=%s kg/m^^3, p=%s Pa, T=%s K, u=%s J/kg",
                                     soln.get_value_str(ib, i, "rho"), soln.get_value_str(ib, i, "p"),
                                     soln.get_value_str(ib, i, "T"), soln.get_value_str(ib, i, "u"));
                    outFile.writefln("  vel=(%s, %s, %s)m/s, a=%s m/s",
                                     soln.get_value_str(ib, i, "vel.x"), soln.get_value_str(ib, i, "vel.y"),
                                     soln.get_value_str(ib, i, "vel.z"), soln.get_value_str(ib, i, "a"));
                    outFile.writefln("  M_local=%s, pitot_p=%s Pa, total_p=%s Pa, total_h=%s J/kg",
                                     soln.get_value_str(ib, i, "M_local"), soln.get_value_str(ib, i, "pitot_p"),
                                     soln.get_value_str(ib, i, "total_p"), soln.get_value_str(ib, i, "total_h"));
                    outFile.writefln("  mu=%s Pa.s, k=%s W/(m.K)", soln.get_value_str(ib, i, "mu"),
                                     soln.get_value_str(ib, i, "k"));
                    outFile.writefln("  mu_t=%s Pa.s, k_t=%s W/(m.K), tke=%s (m/s)^^2, omega=%s 1/s",
                                     soln.get_value_str(ib, i, "mu_t"), soln.get_value_str(ib, i, "k_t"),
                                     soln.get_value_str(ib, i, "tke"), soln.get_value_str(ib, i, "omega"));
                    outFile.writefln("  massf=[%s]", soln.get_massf_str(ib, i));
                }
            }
        } // end foreach tindx

        if (GlobalConfig.nSolidBlocks > 0) {
            foreach (tindx; tindx_list_to_plot) {
                writeln("  tindx= ", tindx);
                auto soln = new SolidSolution(jobName, ".", tindx, GlobalConfig.nSolidBlocks);
                if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
                if (outputFormat == "gnuplot") {
                    outFile.writeln(soln.solidBlocks[0].variable_names_as_string());
                }
                foreach (ip; 0 .. xp.length) {
                    auto nearest = soln.find_nearest_cell_centre(xp[ip], yp[ip], zp[ip]);
                    size_t ib = nearest[0]; size_t i = nearest[1]; size_t j = nearest[2]; size_t k = nearest[3];
                    if (outputFormat == "gnuplot") {
                        outFile.writeln(soln.solidBlocks[ib].values_as_string(i, j, k));
                    } else {
                        // Assume that pretty format was requested.
                        outFile.writefln("SolidBlock[%d], cell[%d]:", ib, i);
                        outFile.writefln("  pos=(%s, %s, %s)m, volume=%s m^^3",
                                         soln.get_value_str(ib, i, j, k, "pos.x"), soln.get_value_str(ib, i, j, k, "pos.y"),
                                         soln.get_value_str(ib, i, j, k, "pos.z"), soln.get_value_str(ib, i, j, k, "volume"));
                        outFile.writefln("  e=%s J/kg, T=%s K",
                                         soln.get_value_str(ib, i, j, k, "e"), soln.get_value_str(ib, i, j, k, "T"));
                    }
                }
            } // end foreach tindx
        } // end if nSolidBlocks > 0
    } // end if probeStr
    //
    if (sliceListStr.length > 0) {
        writeln("Extracting slices of the flow solution.");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            //
            outFile.writeln(soln.flowBlocks[0].variable_names_as_string(true));
            foreach (sliceStr; sliceListStr.split(";")) {
                auto rangeStrings = sliceStr.split(",");
                auto blk_range = decode_range_indices(rangeStrings[0], 0, soln.nBlocks);
                foreach (ib; blk_range[0] .. blk_range[1]) {
                    auto blk = soln.flowBlocks[ib];
                    // We need to do the decode in the context of each block because
                    // the upper limits to the indices are specific to the block.
                    auto i_range = decode_range_indices(rangeStrings[1], 0, blk.nic);
                    auto j_range = decode_range_indices(rangeStrings[2], 0, blk.njc);
                    auto k_range = decode_range_indices(rangeStrings[3], 0, blk.nkc);
                    foreach (k; k_range[0] .. k_range[1]) {
                        foreach (j; j_range[0] .. j_range[1]) {
                            foreach (i; i_range[0] .. i_range[1]) {
                                outFile.writeln(blk.values_as_string(i,j,k));
                            }
                        }
                    }
                } // end foreach ib
            } // end foreach sliceStr
        } // end foreach tindx
    } // end if sliceListStr
    //
    if (surfaceListStr.length > 0) {
        writeln("Extracting named surfaces of the flow solution.");
        writeln("writing VTK-XML files to directory \"", plotDir, "\"");
        ensure_directory_is_present(plotDir);
        string surfaceCollectionName = outputFileName;
        if (surfaceCollectionName.length == 0) {
            throw new Exception("Expected name for surface collection to be provided with --output-file");
        }
        File pvdFile = begin_PVD_file(plotDir~"/"~surfaceCollectionName~".pvd");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            string pvtuFileName = surfaceCollectionName~format("-t%04d", tindx)~".pvtu";
            add_time_stamp_to_PVD_file(pvdFile, soln.sim_time, pvtuFileName);
            File pvtuFile = begin_PVTU_file(plotDir~"/"~pvtuFileName, soln.flowBlocks[0].variableNames);
            foreach (surfaceStr; surfaceListStr.split(";")) {
                auto itemStrings = surfaceStr.split(",");
                size_t blk_indx = to!size_t(itemStrings[0]);
                string boundary_id = itemStrings[1];
                size_t boundary_indx;
                if (canFind(face_name, boundary_id)) {
                    boundary_indx = face_index(boundary_id);
                } else {
                    boundary_indx = to!size_t(boundary_id);
                }
                string vtuFileName = format("%s-t%04d-blk-%04d-surface-%s.vtu",
                                         surfaceCollectionName, tindx, blk_indx, boundary_id);
                auto surf_grid = soln.gridBlocks[blk_indx].get_boundary_grid(boundary_indx);
                size_t[] surf_cells = soln.gridBlocks[blk_indx].get_list_of_boundary_cells(boundary_indx);
                size_t new_dimensions = surf_grid.dimensions;
                // The following should work for both structured and unstructured grids.
                size_t new_nic = max(surf_grid.niv-1, 1);
                size_t new_njc = max(surf_grid.njv-1, 1);
                size_t new_nkc = max(surf_grid.nkv-1, 1);
                assert(new_nic*new_njc*new_nkc == surf_cells.length, "mismatch is number of cells");
                auto surf_flow = new BlockFlow(soln.flowBlocks[blk_indx], surf_cells,
                                               new_dimensions, new_nic, new_njc, new_nkc);
                add_piece_to_PVTU_file(pvtuFile, vtuFileName);
                write_VTU_file(surf_flow, surf_grid, plotDir~"/"~vtuFileName, binary_format);
            } // end foreach surfaceStr
            finish_PVTU_file(pvtuFile);
        } // end foreach tindx
        finish_PVD_file(pvdFile);
    } // end if surfaceListStr
    //
    if (extractStreamStr.length > 0) {
        writeln("Extracting data along a streamline of the flow solution.");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        extractStreamStr = extractStreamStr.strip();
        extractStreamStr = extractStreamStr.replaceAll(regex("\""), "");
        double[] xp, yp, zp;
        foreach(triple; extractStreamStr.split(";")) {
            auto items = triple.split(",");
            xp ~= to!double(items[0]);
            yp ~= to!double(items[1]);
            zp ~= to!double(items[2]);
        }
        double stepSize = 1e-06; // set a temporal step size
        double xInit, yInit, zInit;
        double xOld, yOld, zOld;
        double xNew, yNew, zNew;
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            outFile.writeln("# xStreamPos ", "yStreamPos ", "zStreamPos ", "relDistance ",
                            soln.flowBlocks[0].variable_names_as_string());
            foreach (ip; 0 .. xp.length) {
                outFile.writeln("# streamline locus point: ", xp[ip], ", ", yp[ip], ", ", zp[ip]);
                auto identity = soln.find_enclosing_cell(xp[ip], yp[ip], zp[ip]);
                size_t ib = identity[0]; size_t idx = identity[1]; size_t found = identity[2];
                if (found == 0) { // out of domain bounds
                    writeln("User defined point not in solution domain bounds");
                    break;
                }
                else { // store initial cell data
                    xInit = soln.flowBlocks[ib]["pos.x", idx];
                    yInit = soln.flowBlocks[ib]["pos.y", idx];
                    zInit = soln.flowBlocks[ib]["pos.z", idx];
                    outFile.writeln(xInit, " ", yInit, " ", zInit, " ",
                                    soln.flowBlocks[ib].values_as_string(idx));
                }
                // we need to travel both forward (direction = 1) and backward (direction = -1)
                int[] direction = [-1, 1];
                double min = 1e-6;
                foreach (direct; direction) {
                    found = 1;
                    xOld = xInit; yOld = yInit; zOld = zInit;
                    double distance = 0.0; // relative distance along streamline
                    while (found == 1) { // while we have a cell in the domain
                        double vx = soln.flowBlocks[ib]["vel.x", idx];
                        double vy = soln.flowBlocks[ib]["vel.y", idx];
                        double vz = soln.flowBlocks[ib]["vel.z", idx];
                        double dx = direct*vx*stepSize;
                        double dy = direct*vy*stepSize;
                        double dz = direct*vz*stepSize;
                        distance += direct*sqrt(dx*dx + dy*dy + dz*dz);
                        xNew = xOld + dx; yNew = yOld + dy; zNew = zOld + dz;
                        identity = soln.find_enclosing_cell(xNew, yNew, zNew);
                        if (identity[0] == ib && identity[1] == idx) {
                            // did not step outside current cell
                            stepSize = stepSize*2.0; found = identity[2];
                        } else {
                            ib = identity[0]; idx = identity[1]; found = identity[2];
                            if (found == 1) {
                                outFile.writeln(xNew, " ", yNew, " ", zNew, " ", distance, " ",
                                                soln.flowBlocks[ib].values_as_string(idx));
                            }
                            xOld = xNew; yOld = yNew; zOld = zNew;
                            stepSize = 1e-06;
                        } // end else
                    } // end while
                } // end foreach direction
            } // end for each xp.length
        } // end foreach tindx
    } // end if streamlineStr
    //
    if (extractLineStr.length > 0) {
        writeln("Extracting data along a straight line between end points.");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        extractLineStr = extractLineStr.strip();
        extractLineStr = extractLineStr.replaceAll(regex("\""), "");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            outFile.writeln(soln.flowBlocks[0].variable_names_as_string(true));
            size_t[2][] cells_found; // accumulate the identies of the cells found here
            foreach(lineStr; extractLineStr.split(";")) {
                auto items = lineStr.split(",");
                if (items.length != 7) {
                    string errMsg = "The 'extract-line' string requires exactly 7 values.\n";
                    errMsg ~= format("You have provided %d items.\n", items.length);
                    errMsg ~= format("The problematic string is: %s\n", lineStr);
                    throw new Error(errMsg);
                }
                Vector3 p0 = Vector3(to!double(items[0]), to!double(items[1]), to!double(items[2]));
                Vector3 p1 = Vector3(to!double(items[3]), to!double(items[4]), to!double(items[5]));
                size_t n = to!size_t(items[6]);
                auto count = soln.find_enclosing_cells_along_line(p0, p1, n, cells_found);
                writeln("# Info: Found ", count, " cells from point ", p0, " to point ", p1);
            } // end foreach lineStr
            foreach(i; 0 .. cells_found.length) {
                size_t ib = cells_found[i][0]; size_t idx = cells_found[i][1];
                outFile.writeln(soln.flowBlocks[ib].values_as_string(idx));
            }
        } // end foreach tindx
    } // end if extractLineStr

    if (extractSolidLineStr.length > 0) {
        writeln("Extracting data along a straight line between end points in solid domains.");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        extractSolidLineStr = extractSolidLineStr.strip();
        extractSolidLineStr = extractSolidLineStr.replaceAll(regex("\""), "");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new SolidSolution(jobName, ".", tindx, GlobalConfig.nSolidBlocks);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            outFile.writeln(soln.solidBlocks[0].variable_names_as_string(true));
            size_t[2][] cells_found; // accumulate the identies of the cells found here
            foreach(lineStr; extractSolidLineStr.split(";")) {
                auto items = lineStr.split(",");
                if (items.length != 7) {
                    string errMsg = "The 'extract-solid-line' string requires exactly 7 values.\n";
                    errMsg ~= format("You have provided %d items.\n", items.length);
                    errMsg ~= format("The problematic string is: %s\n", lineStr);
                    throw new Error(errMsg);
                }
                Vector3 p0 = Vector3(to!double(items[0]), to!double(items[1]), to!double(items[2]));
                Vector3 p1 = Vector3(to!double(items[3]), to!double(items[4]), to!double(items[5]));
                size_t n = to!size_t(items[6]);
                auto count = soln.find_enclosing_cells_along_line(p0, p1, n, cells_found);
                writeln("# Info: Found ", count, " cells from point ", p0, " to point ", p1);
            } // end foreach lineStr
            foreach(i; 0 .. cells_found.length) {
                size_t ib = cells_found[i][0]; size_t idx = cells_found[i][1];
                outFile.writeln(soln.solidBlocks[ib].values_as_string(idx));
            }
        } // end foreach tindx
    } // end if extractSolidLineStr
    //
    if (computeLoadsOnGroupStr.length > 0) {
        writeln("Computing loads on group: " ~ computeLoadsOnGroupStr ~ " .");
        // The output may go to a user-specified file, or stdout.
        File outFile;
        if (outputFileName.length > 0) {
            outFile = File(outputFileName, "w");
            writeln("Output will be sent to File: ", outputFileName);
        } else {
            outFile = stdout;
        }
        string groupTag = computeLoadsOnGroupStr;
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            double Fx = 0.0; double Fy = 0.0; double Fz = 0.0; double F = 0.0; double q = 0.0;
            foreach (blk_indx; 0..GlobalConfig.nFluidBlocks) {
                foreach (boundary_indx; 0..soln.flowBlocks[blk_indx].bcGroups.length) {
                    auto surf_grid = soln.gridBlocks[blk_indx].get_boundary_grid(boundary_indx);
                    size_t[] surf_cells = soln.gridBlocks[blk_indx].get_list_of_boundary_cells(boundary_indx);
                    size_t new_dimensions = surf_grid.dimensions;
                    // The following should work for both structured and unstructured grids.
                    size_t new_nic = max(surf_grid.niv-1, 1);
                    size_t new_njc = max(surf_grid.njv-1, 1);
                    size_t new_nkc = max(surf_grid.nkv-1, 1);
                    assert(new_nic*new_njc*new_nkc == surf_cells.length, "mismatch is number of cells");
                    auto surf_flow = new BlockFlow(soln.flowBlocks[blk_indx], surf_cells,
                                                   new_dimensions, new_nic, new_njc, new_nkc);
                    // At this stage we should have a surface flow structure, and a sufrace grid.
                    
                }
            }
        }
    } // end if computeLoadsOnGroupStr
    //
    if (normsStr.length > 0) {
        writeln("Norms for variables.");
        normsStr = normsStr.strip();
        normsStr = normsStr.replaceAll(regex("\""), "");
        foreach (tindx; tindx_list_to_plot) {
            writeln("  tindx= ", tindx);
            auto soln = new FlowSolution(jobName, ".", tindx, GlobalConfig.nFluidBlocks);
            soln.add_aux_variables(addVarsList);
            if (luaRefSoln.length > 0) soln.subtract_ref_soln(luaRefSoln);
            //
            SolidSolution solidSoln;
            if ( GlobalConfig.nSolidBlocks > 0 ) {
                solidSoln = new SolidSolution(jobName, ".", tindx, GlobalConfig.nSolidBlocks);
                if (luaRefSoln.length > 0) solidSoln.subtract_ref_soln(luaRefSoln);
            }
            //
            // Work on flow blocks first
            writeln("normsStr= ", normsStr);
            foreach (varName; normsStr.split(",")) {
                writeln("flow: varName= ", varName);
                if (!canFind(soln.flowBlocks[0].variableNames, varName)) {
                    writeln(format("Requested variable name \"%s\" not in list of flow variables.", varName));
                    continue;
                }
                auto norms = soln.compute_volume_weighted_norms(varName, regionStr);
                write("    variable= ", varName, "\n");
                write(format(" L1= %.18e L2= %.18e Linf= %.18e\n",
                             norms[0], norms[1], norms[2]));
                write(" x= ", norms[3], " y= ", norms[4], " z= ", norms[5]);
                write("\n");
            } // end foreach varName
            // Then work on solid blocks
            if ( GlobalConfig.nSolidBlocks > 0 ) {
                writeln("normsStr= ", normsStr);
                foreach (varName; normsStr.split(",")) {
                    writeln("solid: varName= ", varName);
                    if (!canFind(solidSoln.solidBlocks[0].variableNames, varName)) {
                        writeln(format("Requested variable name \"%s\" not in list of solid variables.", varName));
                        continue;
                    }
                    auto norms = solidSoln.compute_volume_weighted_norms(varName, regionStr);
                    write("    variable= ", varName, "\n");
                    write(format(" L1= %.18e L2= %.18e Linf= %.18e\n",
                                 norms[0], norms[1], norms[2]));
                    write(" x= ", norms[3], " y= ", norms[4], " z= ", norms[5]);
                    write("\n");
                } // end foreach varName
            } // end if nSolidBlocks > 0
        } // end foreach tindx
    } // end if normsStr
    //
} // end post_process()

//-----------------------------------------------------------------------

size_t[] decode_range_indices(string rangeStr, size_t first, size_t endplus1)
// Decode strings such as "0:$", ":", "0:3", "$"
// On input, first and endplus1 represent the largest, available range.
// Return the pair of numbers that can be used in a foreach loop range.
{
    if (rangeStr == ":") {
        return [first, endplus1];
    }
    if (canFind(rangeStr, ":")) {
        // We have a range specification to pull apart.
        auto items = rangeStr.split(":");
        first = to!size_t(items[0]);
        if (items.length > 1 && items[1] != "$") {
            // Presume that we have a second integer.
            size_t new_endplus1 = to!size_t(items[1]);
            if (new_endplus1 < endplus1) endplus1 = new_endplus1; 
        }
    } else if (rangeStr == "$") {
        // Wit just a single "$" specified, we want only the last index.
        first = endplus1 - 1;
    }else {
        // Presume that we have a single integer.
        first = to!size_t(rangeStr);
        if (first < endplus1) endplus1 = first+1;
    }
    return [first, endplus1];
} // end decode_range_indices()

double[int] readTimesFile(string jobName)
{
    double[int] times_dict;
    // Read the times file for all tindx values.
    auto timesFile = File(jobName ~ ".times");
    auto line = timesFile.readln().strip();
    while (line.length > 0) {
        if (line[0] != '#') {
            // Process a non-comment line.
            auto tokens = line.split();
            times_dict[to!int(tokens[0])] = to!double(tokens[1]);
        }
        line = timesFile.readln().strip();
    }
    timesFile.close();
    return times_dict;
} // end readTimesFile()

//-----------------------------------------------------------------------

File begin_PVD_file(string fileName)
{
    // Start a Paraview collection file.
    // For each time index, this justs lists the name of the top-level .pvtu file.
    File f = File(fileName, "w");
    f.write("<?xml version=\"1.0\"?>\n");
    f.write("<VTKFile type=\"Collection\" version=\"0.1\" byte_order=\"LittleEndian\">\n");
    f.write("<Collection>\n");
    return f;
}

void add_time_stamp_to_PVD_file(File f, double timeStamp, string pvtuFileName)
{
    f.writef("<DataSet timestep=\"%.18e\" group=\"\" part=\"0\" file=\"%s\"/>\n",
             timeStamp, pvtuFileName);
}

void finish_PVD_file(File f)
{
    f.write("</Collection>\n");
    f.write("</VTKFile>\n");
    f.close();
}

File begin_PVTU_file(string fileName, string[] variableNames, bool includeVelocity=true)
{
    File f = File(fileName, "w");
    f.write("<VTKFile type=\"PUnstructuredGrid\">\n");
    f.write("<PUnstructuredGrid GhostLevel=\"0\">");
    f.write("<PPoints>\n");
    f.write(" <PDataArray type=\"Float32\" NumberOfComponents=\"3\"/>\n");
    f.write("</PPoints>\n");
    f.write("<PCellData>\n");
    foreach (var; variableNames) {
        f.writef(" <DataArray Name=\"%s\" type=\"Float32\" NumberOfComponents=\"1\"/>\n", var);
    }
    if (includeVelocity) {
        f.write(" <PDataArray Name=\"vel.vector\" type=\"Float32\" NumberOfComponents=\"3\"/>\n");
    }
    if (canFind(variableNames,"c.x")) {
        f.write(" <PDataArray Name=\"c.vector\" type=\"Float32\" NumberOfComponents=\"3\"/>\n");
    }
    if (canFind(variableNames,"B.x")) {
        f.write(" <PDataArray Name=\"B.vector\" type=\"Float32\" NumberOfComponents=\"3\"/>\n");
    }
    f.write("</PCellData>\n");
    return f;
} // end begin_PVTU_file()

void add_piece_to_PVTU_file(File f, string fileName)
{
    f.writef("<Piece Source=\"%s\"/>\n", fileName);
}

void finish_PVTU_file(File f)
{
    f.write("</PUnstructuredGrid>\n");
    f.write("</VTKFile>\n");
    f.close();
}

void write_VTU_file(BlockFlow flow, Grid grid, string fileName, bool binary_format)
// Write the cell-centred flow data from a single block (index jb)
// as an unstructured grid of finite-volume cells.
{
    auto fp = File(fileName, "wb"); // We may be writing some binary data.
    ubyte[] binary_data_string;
    ubyte[] binary_data;
    int binary_data_offset = 0;
    bool two_D = (grid.dimensions == 2);
    size_t NumberOfPoints = grid.nvertices;
    if (flow.ncells != grid.ncells) {
        string msg = text("Mismatch between grid and flow grid.ncells=",
                          grid.ncells, " flow.ncells=", flow.ncells);
        throw new FlowSolverException(msg);
    }
    size_t NumberOfCells = flow.ncells;
    fp.write("<VTKFile type=\"UnstructuredGrid\" byte_order=\"BigEndian\">\n");
    fp.write("<UnstructuredGrid>");
    fp.writef("<Piece NumberOfPoints=\"%d\" NumberOfCells=\"%d\">\n",
              NumberOfPoints, NumberOfCells);
    //
    fp.write("<Points>\n");
    fp.write(" <DataArray type=\"Float32\" NumberOfComponents=\"3\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length=0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    foreach (i; 0 .. grid.nvertices) {
        float x = uflowz(grid[i].x);
        float y = uflowz(grid[i].y);
        float z = uflowz(grid[i].z);
        if (binary_format) {
            binary_data ~= nativeToBigEndian(x);
            binary_data ~= nativeToBigEndian(y);
            binary_data ~= nativeToBigEndian(z);
        } else {
            fp.writef(" %.18e %.18e %.18e\n", x,y,z);
        }
    }
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    fp.write("</Points>\n");
    //
    fp.write("<Cells>\n");
    fp.write(" <DataArray type=\"Int32\" Name=\"connectivity\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    foreach (i; 0 .. grid.ncells) {
        auto ids = grid.get_vtx_id_list_for_cell(i);
        if (binary_format) {
            foreach (id; ids) { binary_data ~= nativeToBigEndian(to!int32_t(id)); }
        } else {
            foreach (id; ids) { fp.writef(" %d", id); }
            fp.write("\n");
        }
    } // end foreach i
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    //
    fp.write(" <DataArray type=\"Int32\" Name=\"offsets\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    // Since all of the point-lists are concatenated, these offsets into the connectivity
    // array specify the end of each cell.
    size_t conn_offset = 0;
    foreach (i; 0 .. grid.ncells) {
        conn_offset += grid.number_of_vertices_for_cell(i);
        if (binary_format) {
            binary_data ~= nativeToBigEndian(to!int32_t(conn_offset));
        } else {
            fp.writef(" %d\n", conn_offset);
        }
    } // end foreach i
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    //
    fp.write(" <DataArray type=\"UInt8\" Name=\"types\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    foreach (i; 0 .. grid.ncells) {
        int type_value = grid.vtk_element_type_for_cell(i);
        if (binary_format) {
            binary_data ~= nativeToBigEndian(to!uint8_t(type_value));
        } else {
            fp.writef(" %d\n", type_value);
        }
    } // end foreach i
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    fp.write("</Cells>\n");
    //
    fp.write("<CellData>\n");
    // Write variables from the dictionary.
    foreach (var; flow.variableNames) {
        fp.writef(" <DataArray Name=\"%s\" type=\"Float32\" NumberOfComponents=\"1\"", var);
        if (binary_format) {
            fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
            binary_data.length = 0;
        } else {
            fp.write(" format=\"ascii\">\n");
        }
        foreach (i; 0 .. flow.ncells) {
            if (binary_format) {
                binary_data ~= nativeToBigEndian(to!float(uflowz(flow[var,i])));
            } else {
                fp.writef(" %.18e\n", uflowz(flow[var,i]));
            }
        } // end foreach i
        fp.write(" </DataArray>\n");
        if (binary_format) {
            uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
            binary_data_string ~= nativeToBigEndian(binary_data_count);
            binary_data_string ~= binary_data;
            binary_data_offset += 4 + binary_data.length;
        }
    } // end foreach var
    //
    // Write the special variables:
    // i.e. variables constructed from those in the dictionary.
    fp.write(" <DataArray Name=\"vel.vector\" type=\"Float32\" NumberOfComponents=\"3\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    foreach (i; 0 .. flow.ncells) {
        float x = uflowz(flow["vel.x",i]);
        float y = uflowz(flow["vel.y",i]);
        float z = uflowz(flow["vel.z",i]);
        if (binary_format) {
            binary_data ~= nativeToBigEndian(x);
            binary_data ~= nativeToBigEndian(y);
            binary_data ~= nativeToBigEndian(z);
        } else {
            fp.writef(" %.18e %.18e %.18e\n", x, y, z);
        }
    } // end foreach i
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    //
    if (canFind(flow.variableNames, "c.x")) {
        fp.write(" <DataArray Name=\"c.vector\" type=\"Float32\" NumberOfComponents=\"3\"");
        if (binary_format) {
            fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
            binary_data.length = 0;
        } else {
            fp.write(" format=\"ascii\">\n");
        }
        foreach (i; 0 .. flow.ncells) {
            float x = uflowz(flow["c.x",i]);
            float y = uflowz(flow["c.y",i]);
            float z = uflowz(flow["c.z",i]);
            if (binary_format) {
                binary_data ~= nativeToBigEndian(x);
                binary_data ~= nativeToBigEndian(y);
                binary_data ~= nativeToBigEndian(z);
            } else {
                fp.writef(" %.18e %.18e %.18e\n", x, y, z);
            }
        } // end foreach i
        fp.write(" </DataArray>\n");
        if (binary_format) {
            uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
            binary_data_string ~= nativeToBigEndian(binary_data_count);
            binary_data_string ~= binary_data;
            binary_data_offset += 4 + binary_data.length;
        }
    } // if canFind c.x
    //
    if (canFind(flow.variableNames, "B.x")) {
        fp.write(" <DataArray Name=\"B.vector\" type=\"Float32\" NumberOfComponents=\"3\"");
        if (binary_format) {
            fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
            binary_data.length = 0;
        } else {
            fp.write(" format=\"ascii\">\n");
        }
        foreach (i; 0 .. flow.ncells) {
            float x = uflowz(flow["B.x",i]);
            float y = uflowz(flow["B.y",i]);
            float z = uflowz(flow["B.z",i]);
            if (binary_format) {
                binary_data ~= nativeToBigEndian(x);
                binary_data ~= nativeToBigEndian(y);
                binary_data ~= nativeToBigEndian(z);
            } else {
                fp.writef(" %.18e %.18e %.18e\n", x, y, z);
            }
        } // end foreach i
        fp.write(" </DataArray>\n");
        if (binary_format) {
            uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
            binary_data_string ~= nativeToBigEndian(binary_data_count);
            binary_data_string ~= binary_data;
            binary_data_offset += 4 + binary_data.length;
        }
    } // if canFind B.x
    //
    fp.write("</CellData>\n");
    fp.write("</Piece>\n");
    fp.write("</UnstructuredGrid>\n");
    if (binary_format) {
        fp.write("<AppendedData encoding=\"raw\">\n");
        fp.write('_');
        fp.rawWrite(binary_data_string);
        fp.write("</AppendedData>\n");
    }
    fp.write("</VTKFile>\n");
    fp.close();
    return;
} // end write_VTU_file()


// This version is for the solid domain.
void write_VTU_file(SBlockSolid solid, StructuredGrid grid, string fileName, bool binary_format)
// Write the cell-centred flow data from a single block (index jb)
// as an unstructured grid of finite-volume cells.
{
    auto fp = File(fileName, "wb"); // We may be writing some binary data.
    //auto solid = soln.solidBlocks[jb];
    //auto grid = soln.gridBlocks[jb];
    ubyte[] binary_data_string;
    ubyte[] binary_data;
    int binary_data_offset = 0;
    size_t niv = grid.niv; size_t njv = grid.njv; size_t nkv = grid.nkv;
    size_t nic = solid.nic; size_t njc = solid.njc; size_t nkc = solid.nkc;
    bool two_D = (nkv == 1);
    size_t NumberOfPoints = niv * njv * nkv;
    size_t NumberOfCells = nic * njc * nkc;
    fp.write("<VTKFile type=\"UnstructuredGrid\" byte_order=\"BigEndian\">\n");
    fp.write("<UnstructuredGrid>");
    fp.writef("<Piece NumberOfPoints=\"%d\" NumberOfCells=\"%d\">\n",
              NumberOfPoints, NumberOfCells);
    //
    fp.write("<Points>\n");
    fp.write(" <DataArray type=\"Float32\" NumberOfComponents=\"3\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length=0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    size_t vtx_number = 0;
    size_t[][][] vtx_id;
    vtx_id.length = niv;
    foreach (i; 0 .. niv) {
        vtx_id[i].length = njv;
        foreach (j; 0 .. njv) {
            vtx_id[i][j].length = nkv;
        }
    }
    foreach (k; 0 .. nkv) {
        foreach (j; 0 .. njv) {
            foreach (i; 0 .. niv) {
                vtx_id[i][j][k] = vtx_number;
                float x = uflowz(grid[i,j,k].x);
                float y = uflowz(grid[i,j,k].y);
                float z = uflowz(grid[i,j,k].z);
                if (binary_format) {
                    binary_data ~= nativeToBigEndian(x);
                    binary_data ~= nativeToBigEndian(y);
                    binary_data ~= nativeToBigEndian(z);
                } else {
                    fp.writef(" %.18e %.18e %.18e\n", x,y,z);
                }
                vtx_number += 1;
            }
        }
    }
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    fp.write("</Points>\n");
    //
    fp.write("<Cells>\n");
    fp.write(" <DataArray type=\"Int32\" Name=\"connectivity\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    foreach (k; 0 .. nkc) {
        foreach (j; 0 .. njc) {
            foreach (i; 0 .. nic) {
                if (two_D) {
                    auto ids = [vtx_id[i][j][k], vtx_id[i+1][j][k],
                                vtx_id[i+1][j+1][k], vtx_id[i][j+1][k]];
                    if (binary_format) {
                        foreach (id; ids) { binary_data ~= nativeToBigEndian(to!int32_t(id)); }
                    } else {
                        fp.writef(" %d %d %d %d\n", ids[0], ids[1], ids[2], ids[3]);
                    }
                } else {
                    auto ids = [vtx_id[i][j][k], vtx_id[i+1][j][k], 
                                vtx_id[i+1][j+1][k], vtx_id[i][j+1][k],
                                vtx_id[i][j][k+1], vtx_id[i+1][j][k+1], 
                                vtx_id[i+1][j+1][k+1], vtx_id[i][j+1][k+1]];
                    if (binary_format) {
                        foreach (id; ids) { binary_data ~= nativeToBigEndian(to!int32_t(id)); }
                    } else {
                        fp.writef(" %d %d %d %d %d %d %d %d\n", ids[0], ids[1], ids[2],
                                  ids[3], ids[4], ids[5], ids[6], ids[7]);
                    }
                }
            } // end foreach i
        } // end foreach j
    } // end foreach k
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    //
    fp.write(" <DataArray type=\"Int32\" Name=\"offsets\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    // Since all of the point-lists are concatenated, these offsets into the connectivity
    // array specify the end of each cell.
    foreach (k; 0 .. nkc) {
        foreach (j; 0 .. njc) {
            foreach (i; 0 .. nic) {
                size_t conn_offset;
                if (two_D) {
                    conn_offset = 4*(1+i+j*nic);
                } else {
                    conn_offset = 8*(1+i+j*nic+k*(nic*njc));
                }
                if (binary_format) {
                    binary_data ~= nativeToBigEndian(to!int32_t(conn_offset));
                } else {
                    fp.writef(" %d\n", conn_offset);
                }
            } // end foreach i
        } // end foreach j
    } // end foreach k
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    //
    fp.write(" <DataArray type=\"UInt8\" Name=\"types\"");
    if (binary_format) {
        fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
        binary_data.length = 0;
    } else {
        fp.write(" format=\"ascii\">\n");
    }
    int type_value;
    if (two_D) {
        type_value = 9; // VTK_QUAD
    } else {
        type_value = 12; // VTK_HEXAHEDRON
    }
    foreach (k; 0 .. nkc) {
        foreach (j; 0 .. njc) {
            foreach (i; 0 .. nic) {
                if (binary_format) {
                    binary_data ~= nativeToBigEndian(to!uint8_t(type_value));
                } else {
                    fp.writef(" %d\n", type_value);
                }
            } // end foreach i
        } // end foreach j
    } // end foreach k
    fp.write(" </DataArray>\n");
    if (binary_format) {
        uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
        binary_data_string ~= nativeToBigEndian(binary_data_count);
        binary_data_string ~= binary_data;
        binary_data_offset += 4 + binary_data.length;
    }
    fp.write("</Cells>\n");
    //
    fp.write("<CellData>\n");
    // Write variables from the dictionary.
    foreach (var; solid.variableNames) {
        fp.writef(" <DataArray Name=\"%s\" type=\"Float32\" NumberOfComponents=\"1\"", var);
        if (binary_format) {
            fp.writef(" format=\"appended\" offset=\"%d\">", binary_data_offset);
            binary_data.length = 0;
        } else {
            fp.write(" format=\"ascii\">\n");
        }
        foreach (k; 0 .. nkc) {
            foreach (j; 0 .. njc) {
                foreach (i; 0 .. nic) {
                    if (binary_format) {
                        binary_data ~= nativeToBigEndian(to!float(uflowz(solid[var,i,j,k])));
                    } else {
                        fp.writef(" %.18e\n", uflowz(solid[var,i,j,k]));
                    }
                } // end foreach i
            } // end foreach j
        } // end foreach k
        fp.write(" </DataArray>\n");
        if (binary_format) {
            uint32_t binary_data_count = to!uint32_t(binary_data.length); // 4-byte count of bytes
            binary_data_string ~= nativeToBigEndian(binary_data_count);
            binary_data_string ~= binary_data;
            binary_data_offset += 4 + binary_data.length;
        }
    } // end foreach var
    //
    fp.write("</CellData>\n");
    fp.write("</Piece>\n");
    fp.write("</UnstructuredGrid>\n");
    if (binary_format) {
        fp.write("<AppendedData encoding=\"raw\">\n");
        fp.write('_');
        fp.rawWrite(binary_data_string);
        fp.write("</AppendedData>\n");
    }
    fp.write("</VTKFile>\n");
    fp.close();
    return;
} // end write_VTU_file()

void write_Tecplot_file(string jobName, string plotDir, FlowSolution soln, int tindx)
{
    ensure_directory_is_present(plotDir);
    auto t = soln.flowBlocks[0].sim_time;
    auto fName = plotDir~"/"~jobName~format("-%.04d", tindx)~".tec";
    auto fp = File(fName, "w");
    fp.writefln("TITLE=\"Job=%s time= %e\"", jobName, t);
    fp.write("VARIABLES= \"X\", \"Y\", \"Z\"");
    int nCtrdVars = 0;
    foreach (var; soln.flowBlocks[0].variableNames) {
        if ( var == "pos.x" || var == "pos.y" || var == "pos.z" ) continue;
        fp.writef(", \"%s\"", var);
        nCtrdVars++;
    }
    fp.write("\n");
    auto ctrdVarsStr = to!string(iota(4,4+nCtrdVars+1));
    foreach (jb; 0 .. soln.nBlocks) {
        auto flow = soln.flowBlocks[jb];
        auto grid = soln.gridBlocks[jb];
        auto nic = flow.nic; auto njc = flow.njc; auto nkc = flow.nkc;
        auto niv = grid.niv; auto njv = grid.njv; auto nkv = grid.nkv;
        fp.writefln("ZONE I=%d J=%d K=%d DATAPACKING=BLOCK", niv, njv, nkv);
        fp.writefln(" SOLUTIONTIME=%e", t);
        fp.writefln(" VARLOCATION=(%s=CELLCENTERED) T=\"fluid-block-%d\"", ctrdVarsStr, jb);
        fp.writefln("# cell-vertex pos.x");
        foreach (k; 0 .. nkv) {
            foreach (j; 0 .. njv) {
                foreach (i; 0 .. niv) {
                    fp.writef(" %e", uflowz(grid[i,j,k].x));
                }
                fp.write("\n");
            }
        }
        fp.writefln("# cell-vertex pos.y");
        foreach (k; 0 .. nkv) {
            foreach (j; 0 .. njv) {
                foreach (i; 0 .. niv) {
                    fp.writef(" %e", uflowz(grid[i,j,k].y));
                }
                fp.write("\n");
            }
        }
        fp.writefln("# cell-vertex pos.z");
        foreach (k; 0 .. nkv) {
            foreach (j; 0 .. njv) {
                foreach (i; 0 .. niv) {
                    fp.writef(" %e", uflowz(grid[i,j,k].z));
                }
                fp.write("\n");
            }
        }
        foreach (var; flow.variableNames) {
            if ( var == "pos.x" || var == "pos.y" || var == "pos.z" ) continue;
            fp.writefln("# cell-centre %s", var);
            foreach (k; 0 .. nkc) {
                foreach (j; 0 .. njc) {
                    foreach (i; 0 .. nic) {
                        fp.writef(" %e", uflowz(flow[var,i,j,k]));
                    }
                    fp.write("\n");
                }
            }
        }
    } // end for jb in 0..nBlocks
    fp.close();
}
