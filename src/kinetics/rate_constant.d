/**
 * rate_constant.d
 * Implements the calculation of reaction rate coefficients.
 *
 * Author: Rowan G.
 */

module kinetics.rate_constant;

import std.math;
import std.algorithm;
import std.typecons;
import std.string;
import nm.complex;
import nm.number;

import util.lua;
import util.lua_service;
import gas;

/++
  RateConstant is a class for computing the rate constant of
  a chemical reaction.
+/

interface RateConstant {
    RateConstant dup();
    @nogc number eval(in GasState Q);
}

/++
 ArrheniusRateConstant uses the Arrhenius model to compute
 a chemical rate constant.

 Strictly speaking, this class implements a modified or
 generalised version of the Arrhenius rate constant.
 Arrhenius expression contains no temperature-dependent
 pre-exponential term. That is, the Arrhenius expression for
 rate constant is:
   k = A exp(-C/T))
 The modified expression is:
   k = A T^n exp(-C/T))

 This class implements that latter expression. It seems overly
 pedantic to provide two separate classes: one for the original
 Arrhenius expression and one for the modified version. Particularly
 given that almost all modern reaction schemes for gas phase chemistry
 provide rate constant inputs in terms of the modified expression.
 Simply setting n=0 gives the original Arrhenius form of the expression.
+/
class ArrheniusRateConstant : RateConstant {
public:
    this(double A, double n, double C)
    {
        _A = A;
        _n = n;
        _C = C;
        _rctIdx = -1;
    }
    this(lua_State* L)
    {
        _A = getDouble(L, -1, "A");
        _n = getDouble(L, -1, "n");
        _C = getDouble(L, -1, "C");
        _rctIdx = getInt(L, -1, "rctIndex");
    }
    ArrheniusRateConstant dup()
    {
        return new ArrheniusRateConstant(_A, _n, _C);
    }
    override number eval(in GasState Q)
    {
        number T = (_rctIdx == -1) ? Q.T : Q.T_modes[_rctIdx];
        return _A*pow(T, _n)*exp(-_C/T);
    }
private:
    double _A, _n, _C;
    int _rctIdx;
}

class ArrheniusRateConstant2 : RateConstant {
public:
    this(double logA, double B, double C)
    {
        _logA = logA;
        _B = B;
        _C = C;
        _rctIdx = -1;
    }
    this(lua_State* L)
    {
        _logA = getDouble(L, -1, "logA");
        _B = getDouble(L, -1, "B");
        _C = getDouble(L, -1, "C");
        _rctIdx = getInt(L, -1, "rctIndex");
    }
    ArrheniusRateConstant2 dup()
    {
        return new ArrheniusRateConstant2(_logA, _B, _C);
    }
    override number eval(in GasState Q)
    {
        number T = (_rctIdx == -1) ? Q.T : Q.T_modes[_rctIdx];
        return exp(_logA + _B*T - _C/T);
    }
private:
    double _logA, _B, _C;
    int _rctIdx;
}

@nogc
number thirdBodyConcentration(in GasState Q, Tuple!(int, double)[] efficiencies, GasModel gmodel)
{
    number val = 0.0;
    foreach (e; efficiencies) {
        int isp = e[0];
        number eff = e[1];
        val += eff * (Q.massf[isp]*Q.rho/gmodel.mol_masses[isp]);
    }
    return val;
}

class LHRateConstant : RateConstant {
public:
    this(ArrheniusRateConstant kInf, ArrheniusRateConstant k0,
         Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        _kInf = kInf.dup();
        _k0 = k0.dup();
        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    this(lua_State* L, Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        lua_getfield(L, -1, "kInf");
        _kInf = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        lua_getfield(L, -1, "k0");
        _k0 = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    LHRateConstant dup()
    {
        return new LHRateConstant(_kInf, _k0, _efficiencies, _gmodel);
    }
    override number eval(in GasState Q)
    {
        number M = thirdBodyConcentration(Q, _efficiencies, _gmodel);
        number kInf = _kInf.eval(Q);
        number k0 = _k0.eval(Q);
        return k0*kInf*M/(k0*M + kInf);
    }
private:
    ArrheniusRateConstant _kInf, _k0;
    Tuple!(int, double)[] _efficiencies;
    GasModel _gmodel;
}

class TroeRateConstant : RateConstant {
public:
    this(ArrheniusRateConstant kInf, ArrheniusRateConstant k0, number Fcent,  bool Fcent_supplied,
         number a, number T1, number T2, number T3, bool T2_supplied,
         Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        _kInf = kInf.dup();
        _k0 = k0.dup();
        _Fcent = Fcent;
        _Fcent_supplied = Fcent_supplied;
        _a = a;
        _T1 = T1;
        _T2 = T2;
        _T3 = T3;
        _T2_supplied = T2_supplied;
        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    this(lua_State* L, Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        lua_getfield(L, -1, "kInf");
        _kInf = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        lua_getfield(L, -1, "k0");
        _k0 = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        // Look for an F_cent value.
        lua_getfield(L, -1, "F_cent");
        if ( !lua_isnil(L, -1) ) {
            _Fcent_supplied = true;
            _Fcent = luaL_checknumber(L, -1);
            lua_pop(L, 1);
        }
        else {
            // Failng that, look for a, T1, T3 and possibly T2
            _Fcent_supplied = false;
            lua_pop(L, 1);
            lua_getfield(L, -1, "a"); _a = luaL_checknumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "T1"); _T1 = luaL_checknumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "T3"); _T3 = luaL_checknumber(L, -1); lua_pop(L, 1);
            lua_getfield(L, -1, "T2");
            if ( !lua_isnumber(L, -1) ) {
                _T2_supplied = false;
                _T2 = 0.0;
            }
            else {
                _T2_supplied = true;
                _T2 = luaL_checknumber(L, -1);
            }
            lua_pop(L, 1);
        }

        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    TroeRateConstant dup()
    {
        return new TroeRateConstant(_kInf, _k0, _Fcent, _Fcent_supplied,
                                    _a, _T1, _T2, _T3, _T2_supplied,
                                    _efficiencies, _gmodel);
    }
    override number eval(in GasState Q)
    {
        immutable double essentially_zero = 1.0e-30;
        number M = thirdBodyConcentration(Q, _efficiencies, _gmodel);
        number kInf = _kInf.eval(Q);
        number k0 = _k0.eval(Q);
        number p_r = k0*M/kInf;
        number log_p_r = log10(fmax(p_r, essentially_zero));
        number T = Q.T;

        if ( !_Fcent_supplied ) {
            _Fcent = (1.0 - _a)*exp(-T/_T3) + _a*exp(-T/_T1);
            if ( _T2_supplied ) {
                _Fcent += exp(-_T2/T);
            }
        }

        number log_F_cent = log10(fmax(_Fcent, essentially_zero));
        number c = -0.4 - 0.67*log_F_cent;
        number n = 0.75 - 1.27*log_F_cent;
        double d = 0.14;

        number numer = log_p_r + c;
        number denom = n - d*numer;
        number frac = numer/denom;
        number log_F = log_F_cent / (1.0 + frac*frac);
        number F = pow(10,log_F);

        return F*k0*kInf*M/(k0*M + kInf);
    }
private:
    ArrheniusRateConstant _kInf, _k0;
    number _Fcent, _a, _T1, _T2, _T3;
    bool _Fcent_supplied, _T2_supplied;
    Tuple!(int, double)[] _efficiencies;
    GasModel _gmodel;
}

/++
 + A pressure-dependent rate constant in the form given by
 + Yungster and Rabinowitz.
 +
 + Yungster and Rabinowitz cite Troe-Golden for this form
 + of rate constant, however, when I traced back to original
 + sources I could *not* find the equation in the form given.
 + Hence, I've named this form directly after that paper.
 +
 + Referece:
 + Yungster and Rabinowitz (1994)
 + Computation of Shock-Induced Combustion Using a Detailed
 + Methane-Air Mechanism.
 + Journal of Propulsion and Power, 10:5, pp. 609--617
 +/

class YRRateConstant : RateConstant {
public:
    this(ArrheniusRateConstant kInf, ArrheniusRateConstant k0, double a, double b, double c,
         Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        _kInf = kInf.dup();
        _k0 = k0.dup();
        _a = a;
        _b = b;
        _c = c;
        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    this(lua_State* L, Tuple!(int, double)[] efficiencies, GasModel gmodel)
    {
        lua_getfield(L, -1, "kInf");
        _kInf = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        lua_getfield(L, -1, "k0");
        _k0 = new ArrheniusRateConstant(L);
        lua_pop(L, 1);

        lua_getfield(L, -1, "a"); _a = luaL_checknumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, -1, "b"); _b = luaL_checknumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, -1, "c"); _c = luaL_checknumber(L, -1); lua_pop(L, 1);

        _efficiencies = efficiencies.dup();
        _gmodel = gmodel;
    }
    YRRateConstant dup()
    {
        return new YRRateConstant(_kInf, _k0, _a, _b, _c, _efficiencies, _gmodel);
    }
    override number eval(in GasState Q)
    {
        immutable double essentially_zero = 1.0e-30;
        number M = thirdBodyConcentration(Q, _efficiencies, _gmodel);
        number kInf = _kInf.eval(Q);
        number k0 = _k0.eval(Q);
        number p_r = k0*M/kInf;
        number log_p_r = log(p_r);
        number T = Q.T;

        number Fc = _a*exp(-_b/T) + (1.0 - _a)*exp(-_c/T);
        number xt = 1.0/(1.0 + log_p_r*log_p_r);

        return kInf*(p_r/(1.0 + p_r))*Fc*xt;
    }
private:
    ArrheniusRateConstant _kInf, _k0;
    double _a, _b, _c;
    Tuple!(int, double)[] _efficiencies;
    GasModel _gmodel;
}

/++
 Park2TRateConstant uses the Arrhenius model to compute
 a chemical rate constant with a modified rate-controlling
 temperature. The rate-controlling temperature is a geometric
 average of the transrotaional and vibroelectronic temperature.

+/

class Park2TRateConstant : RateConstant {
public:
    this(double A, double n, double C, double s)
    {
        _A = A;
        _n = n;
        _C = C;
        _s = s;
    }
    this(lua_State* L)
    {
        _A = getDouble(L, -1, "A");
        _n = getDouble(L, -1, "n");
        _C = getDouble(L, -1, "C");
        _s = getDouble(L, -1, "s");
    }
    Park2TRateConstant dup()
    {
        return new Park2TRateConstant(_A, _n, _C, _s);
    }
    override number eval(in GasState Q)
    {
        number T = pow(Q.T, _s)*pow(Q.T_modes[0], 1.0 - _s);
        return _A*pow(T, _n)*exp(-_C/T);
    }

private:
    double _A, _n, _C, _s;
}

/++
 + Create a RateConstant object based on information in a LuaTable.
 +
 + Expected table format is:
 + tab = {model='Arrhenius',
 +        -- then model-specific parameters follow.
 +        A=..., n=..., C=...}
 +/
RateConstant createRateConstant(lua_State* L, Tuple!(int, double)[] efficiencies, GasModel gmodel)
{
    auto model = getString(L, -1, "model");
    switch (model) {
    case "Arrhenius":
        return new ArrheniusRateConstant(L);
    case "Arrhenius2":
        return new ArrheniusRateConstant2(L);
    case "Lindemann-Hinshelwood":
        return new LHRateConstant(L, efficiencies, gmodel);
    case "Troe":
        return new TroeRateConstant(L, efficiencies, gmodel);
    case "Yungster-Rabinowitz":
        return new YRRateConstant(L, efficiencies, gmodel);
    case "Park":
        return new Park2TRateConstant(L);
    case "fromEqConst":
        return null;
    default:
        string msg = format("The rate constant model: %s could not be created.", model);
        throw new Exception(msg);
    }
}

version(rate_constant_test) {
    import util.msg_service;
    int main() {
        // Test 1. Rate constant for H2 + I2 reaction.
        auto rc = new ArrheniusRateConstant(1.94e14*1e-6, 0.0, 20620.0);
        auto gd = GasState(1, 1);
        gd.T = 700.0;
        // debug { import std.stdio;  writeln("rc=", rc.eval(gd)); } // rc=3.12412e-05
        assert(isClose(3.10850956e-5, rc.eval(gd), 1.0e-2), failedUnitTest());
        // Test 2. Read rate constant parameters for nitrogen dissociation
        // from Lua input and compute rate constant at 4000.0 K
        auto L = init_lua_State();
        luaL_dofile(L, "sample-input/N2-diss.lua");
        lua_getglobal(L, "rate");
        auto rc2 = new ArrheniusRateConstant(L);
        gd.T = 4000.0;
        // debug { import std.stdio;  writeln("rc2=", rc2.eval(gd)); } // rc2=0.00159439
        assert(isClose(0.00159439, rc2.eval(gd), 1.0e-5), failedUnitTest());

        return 0;
    }
}
