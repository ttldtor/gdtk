#! /bin/bash
# prep-gas-files.sh
cp ${DGD_REPO}/src/gas/sample-data/cea-co2-gas-model.lua .
prep-gas co2-5sp-2T.lua co2-5sp-2T.gas
prep-chem co2-5sp-2T.gas co2-5sp-2T-chemistry.lua co2-5sp-2T-chemistry.chem
prep-kinetics co2-5sp-2T.gas co2-5sp-2T-chemistry.chem co2-mixture-energy-exchange.lua co2-mixture-energy-exchange.kin
