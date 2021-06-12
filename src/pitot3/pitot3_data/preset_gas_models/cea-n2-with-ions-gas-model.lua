-- N2 with ions CEA backed gas model
-- I got the species list from intuition and various old PITOT runs with this composition.
-- Chris James (c.james4@uq.edu.au) - 12/06/21

model = "CEAGas"

CEAGas = {
  mixtureName = 'n2-with-ions',
  speciesList = {'N2','N','N2+','N+','N-','e-'},
  reactants = {N2=1.0},
  inputUnits = "moles",
  withIons = true,
  trace = 1.0e-6
}
