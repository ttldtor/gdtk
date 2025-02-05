// config.cu
// Include file for chicken: configuration variables.
// PJ 2022-09-17

#ifndef CONFIG_INCLUDED
#define CONFIG_INCLUDED

#include <iostream>
#include <fstream>
#include <string>
#include <sstream>
#include <map>
#include <stdexcept>
#include "include/nlohmann/json.hpp"

#include "number.cu"
#include "flow.cu"
#include "face.cu"
#include "cell.cu"


using namespace std;
using json = nlohmann::json;

namespace TWallForm {
    constexpr int value = 0;
    constexpr int fun = 1;
};

struct BConfig {
    // Active blocks will be updates during the gas-dynamic update calculations.
    // Blocks that are not active will just have their initial data preserved,
    // so that it can be written out to make the overall structured-grid complete
    // for Paraview.
    bool active;
    //
    // Location of this block in the global array.
    int i, j, k;
    //
    // Active cells are the "real" cells in the simulation.
    // We compute the evolution of the gas-dynamic flow properties within them.
    int nic; // Number of cells i-direction.
    int njc; // Number of cells j-direction.
    int nkc; // Number of cells k-direction.
    int nActiveCells; // Number of active cells (with conserved quantities) in the block.
    //
    // Ghost cells are associated with each block boundary face and
    // will be stored at the end of the active cells collection.
    // The flux calculation functions will dip into this collection for
    // active cells and ghost cells without knowing the difference.
    // Also, for each boundary face, we store some config information
    // to make the boundary-condition code a bit more compact.
    array<int,6> n0c; // number of cells in first index direction for each face.
    array<int,6> n1c; // Number of cells in second index direction for each face.
    array<int,6> nGhostCells; // Number of ghost cells on each face.
    array<int,6> firstGhostCell; // Index of the first ghost cell for each face.
    int nTotalGhostCells; // Total number of ghost cells for the Block
    //
    // Faces in each index direction are used to define cells and
    // to use as locations for flux calculations.
    int n_iFaces;
    int n_jFaces;
    int n_kFaces;
    int nFaces;
    //
    // GPU-related parameters.
    int threads_per_GPUblock = 128;
    int nGPUblocks_for_cells = 0;
    int nGPUblocks_for_faces = 0;
    //
    // Boundary condition codes and associated FlowStates.
    array<int,6> bcCodes;
    array<int,6> bc_fs;
    array<int,6> bc_TWall_form;
    array<double,6> bc_TWall;
    array<int,6> bc_fun;

    __host__
    void fill_in_dimensions(int _nic, int _njc, int _nkc, int threads_per_GPUblock)
    {
        nic = _nic;
        njc = _njc;
        nkc = _nkc;
        nActiveCells = nic*njc*nkc;
        //
        // For the moment assume that all boundary conditions require ghost cells.
        n0c[Face::iminus] = njc; n1c[Face::iminus] = nkc;
        n0c[Face::iplus] = njc; n1c[Face::iplus] = nkc;
        n0c[Face::jminus] = nic; n1c[Face::jminus] = nkc;
        n0c[Face::jplus] = nic; n1c[Face::jplus] = nkc;
        n0c[Face::kminus] = nic; n1c[Face::kminus] = njc;
        n0c[Face::kplus] = nic; n1c[Face::kplus] = njc;
        nTotalGhostCells = 0;
        for (int ib=0; ib < 6; ib++) {
            nGhostCells[ib] = (active) ? 2*n0c[ib]*n1c[ib] : 0;
            firstGhostCell[ib] = (ib > 0) ? firstGhostCell[ib-1] + nGhostCells[ib-1] : nActiveCells;
            nTotalGhostCells += nGhostCells[ib];
        }
        //
        n_iFaces = (nic+1)*njc*nkc;
        n_jFaces = nic*(njc+1)*nkc;
        n_kFaces = nic*njc*(nkc+1);
        nFaces = n_iFaces + n_jFaces + n_kFaces;
        //
        #ifdef CUDA
        // We need to allocate corresponding resources on the GPU.
        nGPUblocks_for_cells = ceil(double(nActiveCells)/threads_per_GPUblock);
        nGPUblocks_for_faces = ceil(double(nFaces)/threads_per_GPUblock);
        #endif
        return;
    }

    // Methods to index the elements making up the block.

    __host__ __device__
    int activeCellIndex(int i, int j, int k) const
    {
        return k*nic*njc + j*nic + i;
    }

    __host__ __device__
    int ghostCellIndex(int faceIndx, int i0, int i1, int depth) const
    {
        int cellIndxOnFace = (active) ? i1*n0c[faceIndx] + i0 : 0;
        int nCellsOnFace = (active) ? n0c[faceIndx]*n1c[faceIndx] : 0;
        return firstGhostCell[faceIndx] + nCellsOnFace*depth + cellIndxOnFace;
    }

    __host__ __device__
    int iFaceIndex(int i, int j, int k) const
    {
        return i*njc*nkc + k*njc + j;
    }

    __host__ __device__
    int jFaceIndex(int i, int j, int k) const
    {
        return n_iFaces + j*nic*nkc + k*nic + i;
    }

    __host__ __device__
    int kFaceIndex(int i, int j, int k) const
    {
        return n_iFaces + n_jFaces + k*nic*njc + j*nic + i;
    }

    __host__ __device__
    int vtxIndex(int i, int j, int k) const
    {
        return k*(nic+1)*(njc+1) + j*(nic+1) + i;
    }


    string toString() const
    {
        ostringstream repr;
        repr << "BConfig(i=" << i << ", j=" << j << ", k=" << k;
        repr << ", bcCodes=["; for (auto c: bcCodes) repr << BCCode::names[c] << ","; repr << "]";
        repr << ", bc_fs=["; for (auto f : bc_fs) repr << f << ","; repr << "]";
        repr << ", bc_fun=["; for (auto f : bc_fun) repr << BCFunction::names[f] << ","; repr << "]";
        repr << ", active=" << active;
        repr << ")";
        return repr.str();
    }
}; // end struct BConfig

__host__
ostream& operator<<(ostream& os, const BConfig cfg)
{
    os << cfg.toString();
    return os;
}


struct Schedule {
    vector<number> t_change; // times at which the value changes
    vector<number> values; // the corresponding values

    string toString() const {
        ostringstream repr;
        repr << "Schedule(";
        repr << "t_change=["; for (auto t : t_change) repr << t << ","; repr << "]";
        repr << "values=["; for (auto v : values) repr << v << ","; repr << "]";
        repr << ")";
        return repr.str();
    }

    number get_value(number t) const
    {
        // Select one of our tabulated schedule of values.
        int i = t_change.size() - 1;
        while ((i > 0) && (t < t_change[i])) { i--; }
        return values[i];
    }

    number interpolate_value(number t) const
    {
        // Attempt an interpolation of the tabulated schedule of values.
        if (t <= t_change[0]) { return values[0]; }
        int n = t_change.size();
        if (t >= t_change[n-1]) { return values[n-1]; }
        // If we get to this point, we must have at least 2 values in our schedule
        // and we can interpolate between a pair of them.
        int i = n - 1;
        while ((i > 0) && (t < t_change[i])) { i--; }
        number frac = (t-t_change[i])/(t_change[i+1]-t_change[i]);
        number value = (1.0-frac)*values[i] + frac*values[i+1];
        return value;
    }
}; // end struct Schedule

__host__
ostream& operator<<(ostream& os, const Schedule sch)
{
    os << sch.toString();
    return os;
}


namespace FluxCalc {
    // Selection of flux calculator happens at compile time,
    // setting flux_calculator below.
    array<string,2> names{"ausmdv", "sbp_asf"};
    //
    constexpr int ausmdv = 0;
    constexpr int sbp_asf = 1;
};

int flux_calc_from_name(string name)
{
    if (name == "ausmdv") return FluxCalc::ausmdv;
    if (name == "sbp_asf"  || name == "sbp-asf") return FluxCalc::sbp_asf;
    return FluxCalc::ausmdv;
}


namespace Config {
    int verbosity = 0;
    int nDevices = 0;
    //
    string job = "job";
    string title = "";
    vector<FlowState> flow_states;
    //
    int nFluidBlocks;
    int nib;
    int njb;
    int nkb;
    vector<int> nics, njcs, nkcs;
    vector<vector<vector<int> > >blk_ids;
    //
    int print_count = 20;
    int cfl_count = 10;
    Schedule dt_plot_schedule;
    Schedule cfl_schedule;
    number dt_init = 1.0e-6;
    number max_time = 1.0e-3;
    int max_step = 100.0;
    //
    int x_order = 2;
    int t_order = 2;
    int flux_calc = FluxCalc::ausmdv;
    int source_terms = SourceTerms::none;
    bool reacting = false;
    bool viscous = false;
    //
    // GPU-related parameters.
    int threads_per_GPUblock = 128;
}


vector<BConfig> read_config_file(string fileName)
{
    if (Config::verbosity > 0) cout << "Reading JSON config file." << endl;
    json jsonData;
    ifstream f(fileName, ifstream::binary);
    if (f) {
        ostringstream ss; ss << f.rdbuf();
        string text = ss.str();
        if (Config::verbosity > 1) cout << "File content:\n" << text << endl;
        if (f) {
            jsonData = json::parse(text);
        } else {
            cerr << "Could not read all of config.json file." << endl;
        }
        f.close();
        if (Config::verbosity > 0) cout << "Finished reading JSON file." << endl;
    } else {
        throw runtime_error("Could not open ifstream for config.json.");
    }
    Config::title = jsonData["title"].get<string>();
    if (Config::verbosity > 0) cout << "  title: " << Config::title << endl;
    //
    // Check that we have consistent gas model.
    map<string, number> gas_model_data = jsonData["gas_model"].get<map<string, number> >();
    if (!approxEquals(GasModel::g, gas_model_data["gamma"], 1.0e-6) ||
        !approxEquals(GasModel::R, gas_model_data["R"], 1.0e-6) ||
        !approxEquals(GasModel::q, gas_model_data["q"], 1.0e-6) ||
        !approxEquals(GasModel::alpha, gas_model_data["alpha"], 1.0e-6) ||
        !approxEquals(GasModel::Ti, gas_model_data["Ti"], 1.0e-6) ||
        !approxEquals(GasModel::Cv, gas_model_data["Cv"], 1.0e-6)) {
        cerr << "  gas_model_data: gamma:" << gas_model_data["gamma"]
             << " R:" << gas_model_data["R"]
             << " q:" << gas_model_data["q"]
             << " alpha:" << gas_model_data["alpha"]
             << " Ti:" << gas_model_data["Ti"]
             << " Cv:" << gas_model_data["Cv"]
             << endl;
        throw runtime_error("Incorrect gas model data");
    }
    //
    // Check that we have consistent names in the flow zip archives.
    vector<string> iovar_names = jsonData["iovar_names"].get<vector<string> >();
    for (int i=0; i < IOvar::n; ++i) {
        if (iovar_names[i] != IOvar::names[i]) {
            cout << "Mismatched iovar: " << iovar_names[i] << IOvar::names[i] << endl;
        }
    }
    //
    int n_flow_states = jsonData["n_flow_states"].get<int>();
    vector<json> flow_states_json = jsonData["flow_states"].get<vector<json> >();
    for (auto fsj: flow_states_json) {
        auto gas = GasState{};
        gas.p=fsj["gas"]["p"].get<number>();
        gas.T=fsj["gas"]["T"].get<number>();
        gas.YB=fsj["gas"]["YB"].get<number>();
        gas.update_from_pT();
        auto vel = fsj["vel"].get<vector<number> >();
        Config::flow_states.push_back(FlowState{gas, Vector3{vel[0], vel[1], vel[2]}});
    }
    if (Config::verbosity > 0) {
        cout << "  flow_states: [";
        for (auto fs : Config::flow_states) cout << fs << ",";
        cout << "]" << endl;
    }
    //
    // Block configs appear in the JSON file in order of their definition in the Python input script.
    // This index is the block id and is different to the i,j,k indices into the block array.
    //
    Config::nFluidBlocks = jsonData["n_fluid_blocks"].get<int>();
    Config::nib = jsonData["nib"].get<int>();
    Config::njb = jsonData["njb"].get<int>();
    Config::nkb = jsonData["nkb"].get<int>();
    if (Config::verbosity > 0) {
        cout << "  nib: " << Config::nib << endl;
        cout << "  njb: " << Config::njb << endl;
        cout << "  nkb: " << Config::nkb << endl;
    }
    //
    Config::nics = jsonData["nics"].get<vector<int> >();
    Config::njcs = jsonData["njcs"].get<vector<int> >();
    Config::nkcs = jsonData["nkcs"].get<vector<int> >();
    if (Config::verbosity > 0) {
        cout << "  nics: ["; for (auto i : Config::nics) cout << i << ","; cout << "]" << endl;
        cout << "  njcs: ["; for (auto i : Config::njcs) cout << i << ","; cout << "]" << endl;
        cout << "  nkcs: ["; for (auto i : Config::nkcs) cout << i << ","; cout << "]" << endl;
    }
    //
    Config::blk_ids = jsonData["blk_ids"].get<vector<vector<vector<int> > > >();
    if (Config::verbosity > 0) {
        for (int k=0; k < Config::nkb; k++) {
            for (int j=0; j < Config::njb; j++) {
                for (int i=0; i < Config::nib; i++) {
                    cout << "  blk_ids[" << i << "," << j << "," << k << "]=" << Config::blk_ids[i][j][k] << endl;
                }
            }
        }
    }
    //
    vector<json> fluid_blocks_json = jsonData["fluid_blocks"].get<vector<json> >();
    vector<BConfig> blk_configs;
    for (auto blk_json : fluid_blocks_json) {
        BConfig cfg;
        cfg.i = blk_json["i"].get<int>();
        cfg.j = blk_json["j"].get<int>();
        cfg.k = blk_json["k"].get<int>();
        cfg.active = blk_json["active"].get<bool>();
        map<string,json> bcs_json = blk_json["bcs"].get<map<string,json> >();
        for (auto name : Face::names) {
            map<string,json> bc = bcs_json[name].get<map<string,json> >();
            int i = Face_indx_from_name(name);
            cfg.bcCodes[i] = BC_code_from_name(bc["tag"].get<string>());
            cfg.bc_fs[i] = 0; // Default flowstate index.
            if (cfg.bcCodes[i] == BCCode::inflow) {
                cfg.bc_fs[i] = bc["flow_state_index"].get<int>();
            }
            if (cfg.bcCodes[i] == BCCode::wall_no_slip_fixed_T) {
                cfg.bc_TWall_form[i] = TWallForm::value;
                if (bc["form"].get<string>() == "fun") cfg.bc_TWall_form[i] = TWallForm::fun;
                cfg.bc_TWall[i] = bc["value"].get<double>();
            }
            cfg.bc_fun[i] = 0; // Default function index.
            if (cfg.bcCodes[i] == BCCode::inflow_function) {
                cfg.bc_fun[i] = BC_function_from_name(bc["tag"].get<string>());
            }
        }
        if (Config::verbosity > 0) {
            cout << "  blk=" << blk_configs.size() << " config=" << cfg << endl;
        }
        blk_configs.push_back(cfg);
    }
    if (Config::nFluidBlocks != blk_configs.size()) {
        throw runtime_error("Did not read the correct number of block configurations: "+
                            to_string(Config::nFluidBlocks)+" "+to_string(blk_configs.size()));
    }
    //
    Config::x_order = jsonData["x_order"].get<int>();
    Config::t_order = jsonData["t_order"].get<int>();
    Config::flux_calc = flux_calc_from_name(jsonData["flux_calc"].get<string>());
    Config::source_terms = source_terms_from_name(jsonData["source_terms"].get<string>());
    Config::dt_init = jsonData["dt_init"].get<number>();
    Config::max_time = jsonData["max_time"].get<number>();
    Config::max_step = jsonData["max_step"].get<int>();
    vector<number> cfl_times = jsonData["cfl_times"].get<vector<number> >();
    vector<number> cfl_values = jsonData["cfl_values"].get<vector<number> >();
    Config::cfl_schedule = Schedule{cfl_times, cfl_values};
    Config::cfl_count = jsonData["cfl_count"].get<int>();
    Config::print_count = jsonData["print_count"].get<int>();
    vector<number> t_change = jsonData["t_change"].get<vector<number> >();
    vector<number> dt_plot = jsonData["dt_plot"].get<vector<number> >();
    Config::dt_plot_schedule = Schedule{t_change, dt_plot};
    Config::reacting = jsonData["reacting"].get<bool>();
    Config::viscous = jsonData["viscous"].get<bool>();
    Config::threads_per_GPUblock = jsonData["threads_per_gpu_block"].get<int>();
    if (Config::verbosity > 0) {
        cout << "  x_order=" << Config::x_order << endl;
        cout << "  t_order=" << Config::t_order << endl;
        cout << "  flux_calc=" << FluxCalc::names[Config::flux_calc] << endl;
        cout << "  source_terms=" << SourceTerms::names[Config::source_terms] << endl;
        cout << "  dt_init=" << Config::dt_init << endl;
        cout << "  max_time=" << Config::max_time << endl;
        cout << "  max_step=" << Config::max_step << endl;
        cout << "  cfl_count=" << Config::cfl_count << endl;
        cout << "  cfl_schedule=" << Config::cfl_schedule << endl;
        cout << "  print_count=" << Config::print_count << endl;
        cout << "  dt_plot_schedule=" << Config::dt_plot_schedule << endl;
        cout << "  viscous=" << Config::viscous << endl;
        cout << "  reacting=" << Config::reacting << endl;
        cout << "  threads_per_gpu_block=" << Config::threads_per_GPUblock << endl;
    }
    return blk_configs;
} // end read_config_file()

#endif
