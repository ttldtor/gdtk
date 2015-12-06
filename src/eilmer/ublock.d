// ublock.d
// Class for unstructured blocks of cells, for use within Eilmer4.
// Peter J. 2014-11-07 first serious cut.

module ublock;

import std.conv;
import std.file;
import std.json;
import std.stdio;
import std.format;
import std.string;
import std.array;
import std.math;

import util.lua;
import json_helper;
import lua_helper;
import gzip;
import geom;
import sgrid;
import usgrid;
import gas;
import kinetics;
import globalconfig;
import globaldata;
import flowstate;
import fluxcalc;
import viscousflux;
import fvcore;
import fvvertex;
import fvinterface;
import fvcell;
import onedinterp;
import block;
import bc;

class UBlock: Block {
public:
    size_t ncells;
    size_t nvertices;
    size_t nfaces;
    size_t nboundaries;
    UnstructuredGrid grid;

public:
    this(in int id, JSONValue json_data)
    {
	label = getJSONstring(json_data, "label", "");
	super(id, Grid_t.unstructured_grid, label);
	ncells = getJSONint(json_data, "ncells", 0);
	nvertices = getJSONint(json_data, "nvertices", 0);
	nfaces = getJSONint(json_data, "nfaces", 0);
	nboundaries = getJSONint(json_data, "nboundaries", 0);
	active = getJSONbool(json_data, "active", true);
	omegaz = getJSONdouble(json_data, "omegaz", 0.0);
    } // end constructor from json

    override void init_lua_globals()
    {
	lua_pushinteger(myL, ncells); lua_setglobal(myL, "ncells");
	lua_pushinteger(myL, nvertices); lua_setglobal(myL, "nvertices");
	lua_pushinteger(myL, nfaces); lua_setglobal(myL, "nfaces");
	lua_pushinteger(myL, nboundaries); lua_setglobal(myL, "nboundaries");
	lua_pushinteger(myL, Face.north); lua_setglobal(myL, "north");
	lua_pushinteger(myL, Face.east); lua_setglobal(myL, "east");
	lua_pushinteger(myL, Face.south); lua_setglobal(myL, "south");
	lua_pushinteger(myL, Face.west); lua_setglobal(myL, "west");
	lua_pushinteger(myL, Face.top); lua_setglobal(myL, "top");
	lua_pushinteger(myL, Face.bottom); lua_setglobal(myL, "bottom");
    } // end init_lua_globals()

    override void init_boundary_conditions(JSONValue json_data)
    // Initialize boundary conditions after the blocks are fully constructed,
    // because we want access to the full collection of valid block references.
    {
	foreach (boundary; 0 .. nboundaries) {
	    string json_key = format("boundary_%d", boundary);
	    auto bc_json_data = json_data[json_key];
	    bc ~= make_BC_from_json(bc_json_data, id, to!int(boundary));
	}
    } // end init_boundary_conditions()

    override string toString() const
    {
	char[] repr;
	repr ~= "UBlock(unstructured_grid, ";
	repr ~= "id=" ~ to!string(id);
	repr ~= " label=\"" ~ label ~ "\"";
	repr ~= ", active=" ~ to!string(active);
	repr ~= ", grid_type=\"" ~ gridTypeName(grid_type) ~ "\"";
	repr ~= ", omegaz=" ~ to!string(omegaz);
	repr ~= ", ncells=" ~ to!string(ncells);
	repr ~= ", nvertices=" ~ to!string(nvertices);
	repr ~= ", nfaces=" ~ to!string(nfaces);
	repr ~= ", \n    bc=[b_" ~ to!string(0) ~ "=" ~ to!string(bc[0]);
	foreach (i; 1 .. bc.length) {
	    repr ~= ",\n        b_" ~ to!string(i) ~ "=" ~ to!string(bc[i]);
	}
	repr ~= "\n       ]"; // end bc list
	repr ~= ")";
	return to!string(repr);
    }

    // The following 5 access methods are here to match the structured-grid API
    // but they're really not intended for serious use on the unstructured-grid.
    @nogc 
    override ref FVCell get_cell(size_t i, size_t j, size_t k=0) 
    {
	return cells[i]; // j, k ignored
    }
    @nogc 
    override ref FVInterface get_ifi(size_t i, size_t j, size_t k=0) 
    {
	return faces[i];
    }
    @nogc
    override ref FVInterface get_ifj(size_t i, size_t j, size_t k=0)
    {
	return faces[i];
    }
    @nogc
    override ref FVInterface get_ifk(size_t i, size_t j, size_t k=0)
    {
	return faces[i];
    }
    @nogc
    override ref FVVertex get_vtx(size_t i, size_t j, size_t k=0)
    {
	return vertices[i];
    }

    override void init_grid_and_flow_arrays(string gridFileName)
    {
	grid = new UnstructuredGrid(gridFileName, "gziptext");
	if (grid.nvertices != nvertices) {
	    throw new Error(format("UnstructuredGrid: incoming grid has %d vertices " ~
				   "but expected %d vertices.", grid.nvertices, nvertices));
	}
	if (grid.nfaces != nfaces) {
	    throw new Error(format("UnstructuredGrid: incoming grid has %d faces " ~
				   "but expected %d faces.", grid.nfaces, nfaces));
	}
	if (grid.ncells != ncells) {
	    throw new Error(format("UnstructuredGrid: incoming grid has %d cells " ~
				   "but expected %d cells.", grid.ncells, ncells));
	}
	// Assemble array storage for finite-volume cells, etc.
	foreach (i, v; grid.vertices) {
	    auto new_vtx = new FVVertex(myConfig.gmodel);
	    new_vtx.pos[0] = v;
	    new_vtx.id = i;
	    vertices ~= new_vtx;
	}
	foreach (i, f; grid.faces) {
	    auto new_face = new FVInterface(myConfig.gmodel);
	    new_face.id = i;
	    faces ~= new_face;
	}
	foreach (i, c; grid.cells) {
	    auto new_cell = new FVCell(myConfig);
	    new_cell.id = i;
	    cells ~= new_cell;
	}
	// Bind the interfaces, vertices and cells together, 
	// using the indices stored in the unstructured grid.
	foreach (i, f; faces) {
	    foreach (j; grid.faces[i].vtx_id_list) {
		f.vtx ~= vertices[j];
	    }
	}
	foreach (i, c; cells) {
	    foreach (j; grid.cells[i].vtx_id_list) {
		c.vtx ~= vertices[j];
	    }
	    auto nf = grid.cells[i].face_id_list.length;
	    if (nf != grid.cells[i].outsign_list.length) {
		throw new Error(format("Mismatch in face_id_list, outsign_list lengths: %d %d",
				       grid.cells[i].face_id_list.length,
				       grid.cells[i].outsign_list.length));
	    }
	    foreach (j; 0 .. nf) {
		auto my_face = faces[grid.cells[i].face_id_list[j]];
		auto my_outsign = grid.cells[i].outsign_list[j];
		c.iface ~= my_face;
		c.outsign ~= to!double(my_outsign);
		if (my_outsign == 1) {
		    my_face.left_cells ~= c;
		} else {
		    my_face.right_cells ~= c;
		}
	    }
	} // end foreach cells
	// Presently, no face should have more than one cell on its left or right side.
	foreach (f; faces) {
	    if (f.left_cells.length > 1 || f.right_cells.length > 1) {
		string msg = format("Face id= %d too many attached cells: left_cells= ", f.id);
		foreach (c; f.left_cells) { msg ~= to!string(c.id); }
		msg ~= " right_cells= ";
		foreach (c; f.right_cells) { msg ~= to!string(c.id); }
		throw new Error(msg);
	    }
	}
	// Work through the faces on the boundaries and add ghost cells.
	if (nboundaries != grid.nboundaries) {
	    throw new Error(format("Mismatch in number of boundaries: %d %d",
				   nboundaries, grid.nboundaries));
	}
	foreach (bndry; grid.boundaries) {
	    auto nf = bndry.face_id_list.length;
	    if (nf != bndry.outsign_list.length) {
		throw new Error(format("Mismatch in face_id_list, outsign_list lengths: %d %d",
				       bndry.face_id_list.length,
				       bndry.outsign_list.length));
	    }
	    foreach (j; 0 .. nf) {
		auto my_face = faces[bndry.face_id_list[j]];
		auto my_outsign = bndry.outsign_list[j];
		if (my_outsign == 1) {
		    my_face.right_cells ~= new BasicCell(myConfig);
		    my_face.right_cells ~= new BasicCell(myConfig);
		} else {
		    my_face.left_cells ~= new BasicCell(myConfig);
		    my_face.left_cells ~= new BasicCell(myConfig);
		}
	    }
	}
	// [TODO] store references into the FVVertex objects for derivative calc
    } // end init_grid_and_flow_arrays()

    override void compute_primary_cell_geometric_data(int gtl)
    {
	throw new Error("compute_primary_cell_geometric_data() not implemented yet");
	// [TODO] position ghost-cell centres
    }

    override void read_grid(string filename, size_t gtl=0)
    {
	throw new Error("read_grid function NOT implemented for unstructured grid.");
    }

    override void write_grid(string filename, double sim_time, size_t gtl=0)
    // Note that we reuse the StructuredGrid object that was created on the
    // use of read_grid().
    {
	throw new Error("write_grid function not yet implemented for unstructured grid.");
	// [TODO]
    } // end write_grid()

    override double read_solution(string filename, bool overwrite_geometry_data)
    // Note that the position data is read into grid-time-level 0
    // by scan_values_from_string(). 
    // Returns sim_time from file.
    {
	size_t nc;
	double sim_time;
	if (myConfig.verbosity_level >= 1) {
	    writeln("read_solution(): Start block ", id);
	}
	auto byLine = new GzipByLine(filename);
	auto line = byLine.front; byLine.popFront();
	formattedRead(line, " %g", &sim_time);
	line = byLine.front; byLine.popFront();
	// ignore second line; it should be just the names of the variables
	// [TODO] We should test the incoming strings against the current variable names.
	line = byLine.front; byLine.popFront();
	formattedRead(line, "%d", &nc);
	if (nc != ncells) {
	    throw new Error(text("For block[", id, "] we have a mismatch in solution size.",
				 " Have read nc=", nc, " ncells=", ncells));
	}	
	foreach (i; 0 .. ncells) {
	    line = byLine.front; byLine.popFront();
	    cells[i].scan_values_from_string(line, overwrite_geometry_data);
	}
	return sim_time;
    } // end read_solution()

    override void write_solution(string filename, double sim_time)
    // Write the flow solution (i.e. the primary variables at the cell centers)
    // for a single block.
    // This is almost Tecplot POINT format.
    {
	if (myConfig.verbosity_level >= 1) {
	    writeln("write_solution(): Start block ", id);
	}
	auto outfile = new GzipOut(filename);
	auto writer = appender!string();
	formattedWrite(writer, "%20.12e\n", sim_time);
	outfile.compress(writer.data);
	writer = appender!string();
	foreach(varname; variable_list_for_cell(myConfig.gmodel)) {
	    formattedWrite(writer, " \"%s\"", varname);
	}
	formattedWrite(writer, "\n");
	outfile.compress(writer.data);
	writer = appender!string();
	formattedWrite(writer, "%d\n", ncells);
	outfile.compress(writer.data);
	foreach(i; 0 .. ncells) {
	    outfile.compress(" " ~ cells[i].write_values_to_string() ~ "\n");
	}
	outfile.finish();
    } // end write_solution()

    override void compute_distance_to_nearest_wall_for_all_cells(int gtl)
    // Used for the turbulence modelling.
    {
	throw new Error("compute_distance_to_nearest_wall_for_all_cells function not yet implemented for unstructured grid.");
	// [TODO]
    } // end compute_distance_to_nearest_wall_for_all_cells()

    override void propagate_inflow_data_west_to_east()
    {
	throw new Error("propagate_inflow_data_west_to_east() function not implemented for unstructured grid.");
     }

    override void convective_flux()
    {
	throw new Error("convective_flux function not yet implemented for unstructured grid.");
	// [TODO]
    }

    @nogc
    override void copy_into_ghost_cells(int destination_face,
					ref Block src_blk, int src_face, int src_orientation,
					int type_of_copy, bool with_encode)
    {
	assert(false, "copy_into_ghost_cells function not implemented for unstructured grid.");
	// [TODO]
    }

} // end class UBlock
