# Primal
#!/usr/bin/env python
"""
DAFoam run script for the topology optimization
Reference: Alexandersen2022 (10.1007/s00158-022-03420-9) and lot more
"""
# mpirun --mca btl self,tcp -np 8 python runScript.py 2>&1 | tee logOpt.txt
# =============================================================================
# Imports
# =============================================================================
import os
import argparse
import numpy as np
from mpi4py import MPI
import openmdao.api as om
from mphys.multipoint import Multipoint
from dafoam.mphys import DAFoamBuilder, OptFuncs
from mphys.scenario_aerodynamic import ScenarioAerodynamic

parser = argparse.ArgumentParser()
# which optimizer to use. Options are: IPOPT (default), SLSQP, and SNOPT
# NOTE: this case works only with SNOPT
parser.add_argument("-optimizer", help="optimizer to use", type=str, default="ParOpt")
# which task to run. Options are: run_driver (default), run_model, compute_totals, check_totals
parser.add_argument("-task", help="type of run to do", type=str, default="run_model")
args = parser.parse_args()

def createContinuation(
    nIterations,
    startValue,
    endValue,
    method="linear",
    startIteration=None,
    stopIteration=None,
):

    if startIteration is None:
        startIteration = 0

    if stopIteration is None:
        stopIteration = nIterations - 1

    if nIterations < 1:
        raise ValueError("nIterations must be >= 1")

    if startIteration < 0 or startIteration >= nIterations:
        raise ValueError("Invalid startIteration")

    if stopIteration < 0 or stopIteration >= nIterations:
        raise ValueError("Invalid stopIteration")

    if startIteration > stopIteration:
        raise ValueError(
            "startIteration must be <= stopIteration"
        )

    if method == "exponential":
        if startValue <= 0 or endValue <= 0:
            raise ValueError(
                "Exponential continuation requires positive values."
            )

    values = []

    for i in range(nIterations):

        # Before continuation
        if i < startIteration:
            value = startValue

        # Continuation region
        elif i <= stopIteration:

            if startIteration == stopIteration:
                fraction = 1.0
            else:
                fraction = (
                    (i - startIteration)
                    / (stopIteration - startIteration)
                )

            if method == "linear":

                value = (
                    startValue
                    + (endValue - startValue) * fraction
                )

            elif method == "exponential":

                value = (
                    startValue
                    * (endValue / startValue) ** fraction
                )

            else:
                raise ValueError(
                    f"Unknown continuation method: {method}"
                )

        # After continuation
        else:
            value = endValue

        values.append(value)

    return values
# =============================================================================
# Design calculations
# =============================================================================
nCells = 800 # reduced hexahedra count for the container example
# Set the parameters for optimization
nContinuation = 5
continuationIterations = list(range(nContinuation))
flowQContinuation = createContinuation(nContinuation,100.0,0.001,"linear",0,nContinuation*2/3)
thermalQContinuation = createContinuation(nContinuation,0.01,100.0,"linear",0,nContinuation*2/3)
betaContinuation = createContinuation(nContinuation,1.0,2.0**10,"exponential",nContinuation*2/3,nContinuation-1)
aMaxFlowContinuation = createContinuation(nContinuation,0.0,1.0e5,"linear",0,nContinuation*2/3)
aMaxThermalContinuation = createContinuation(nContinuation,1.0,1.0e-3,"linear",0,nContinuation*2/3)
aMinThermalContinuation = createContinuation(nContinuation,1.0,1.0,"linear",0,nContinuation*2/3)
radiusFracContinuation = createContinuation(nContinuation,3.5,0.0,"linear",0,nContinuation*2/3)
daOptions = {
    "designSurfaces": ["topWall"],
    "solverName": "ehdFoam_b4R11",
    "primalMinResTol": 1.0e-7,
    "primalMinResTolDiff": 1.0e2,
    "primalBC": {
        "useWallFunction": False,
    },
    "primalVarBounds": {
        "TMin": -1.0,
        "p_rghMin": -1e20,
        "p_rghMax": 1e20,
        "pMin": -1e20,
        "pMax": 1e20,
        "rhoMin": 0.0,

    },
    "topologyOptimization": {
        "alphaProjection": "None", # Helmholtz, None
        "beta": 2.0,
        "flow": {
            "interpolationMethod": "convexRAMPInvert",
            "q": 0.1,
            "aMax": 0.0, # Solid Porosity
            "aMin": 0.0, # Fluid Porosity
        },
        "thermal": {
            "interpolationMethod": "concaveRAMPInvert",
            "q": 0.1,
            "aMax": 1.0, # Solid diffusivity
            "aMin": 1.0, # Fluid diffusivity
        },
        "radiusFrac": 0.0,
        "continuationMethodActive": False,
        "continuation": {
            "iteration": continuationIterations,
            "beta": betaContinuation,
            "radiusFrac": radiusFracContinuation,
            "flow": {
                "q": flowQContinuation,
                "aMax": aMaxFlowContinuation,
            },
            "thermal": {
                "q": thermalQContinuation,
                "aMax": aMaxThermalContinuation,
                # "aMin": aMinThermalContinuation,
            },
        },
    },
    "maxResConLv4JacPCMat": {
        "gammaFilterRes": 2,
        "potentialDifferenceRes": 2,
        "chargeDensityRes": 2,
    },
    "function": {
        "nusseltNumber": {
            "type": "NusseltNumber",
            "source": "allCells",
            "heatFluxPatch": "topWall",
            "scale": 1.0,
            "temperaturePatches": ["topWall", "bottomWall"],
            "length": 1.0,
        },
        "volConstraint": {
            "type": "variableVolSum",
            "varName": "gamma",
            "varType": "scalar",
            "scale": 1.0,
            "source": "allCells",
            "multiplyVol": True,
            "divByTotalVol": True,
        },
    },
    "adjEqnOption": {
        "gmresRelTol": 1.0e-3,
        "gmresMaxIters": 2000,
        "gmresRestart": 2000,
        "pcFillLevel": 1,
        "jacMatReOrdering": "rcm",
        "printInfo": 1,
        "useNonZeroInitGuess": True,
    },
    "normalizeStates": {
        "U": 1.0,
        "p": 1.0,
        "nut": 1.0,
        "phi": 1.0,
    },
    "adjPCLag": 1, # Important for KSP solver convergence (1 works the best)
    "inputInfo": {
        "gammaDV": {
            "type": "field",
            "fieldName": "gammaDV",
            "fieldType": "scalar",
            "distributed": False,
            "components": ["solver", "function"],
        },
    },
}

# Top class to setup the optimization problem
class Top(Multipoint):
    def setup(self):

        # create the builder to initialize the DASolvers
        dafoam_builder = DAFoamBuilder(options=daOptions, mesh_options=None, scenario="aerodynamic")
        dafoam_builder.initialize(self.comm)
        self.add_subsystem("dvs", om.IndepVarComp(), promotes=["*"])
        self.mphys_add_scenario("scenario1", ScenarioAerodynamic(aero_builder=dafoam_builder))
        # self.add_subsystem("obj", om.ExecComp("val=pressurePower")) # Refer Marck2013
        # Objective weight is controlled externally by the weight-continuation
        # loop at the bottom of this script.
        # self.add_subsystem("objectiveWeight", om.IndepVarComp(), promotes=["*"])
        # self.objectiveWeight.add_output("objectiveWeight", val=nonDimScales["continuationScheduler"]["weight"])
        self.add_subsystem("obj", om.ExecComp("val=-nusseltNumber"))

    def configure(self):
        # add the design variables to the dvs component's output
        self.dvs.add_output("gammaDV", val=0.25*np.ones(nCells), distributed=False)
        self.connect("gammaDV", "scenario1.gammaDV")
        # define the design variables to the top level
        self.add_design_var("gammaDV", lower=0.0, upper=1.0, scaler=1.0)
        # add objective and constraints to the top level
        # we can connect any function in daOption to obj's terms
        self.connect("scenario1.aero_post.nusseltNumber", "obj.nusseltNumber")
        # self.connect("scenario1.aero_post.thermalPower", "obj.thermalPower")
        # self.connect("objectiveWeight", "obj.objectiveWeight")
        self.add_objective("obj.val", scaler=1.0)
        # self.add_constraint("scenario1.aero_post.volConstraint", upper = 0.1, scaler=1.0)
        # self.add_constraint("scenario1.aero_post.massFlowRate", equals=0.0, scaler=1.0)

# OpenMDAO setup
prob = om.Problem()
prob.model = Top()
prob.setup(mode="rev")
om.n2(prob, show_browser=False, outfile="mphys.html")

# use pyoptsparse to setup optimization
prob.driver = om.pyOptSparseDriver()
prob.driver.options["optimizer"] = args.optimizer
# options for optimizers
if args.optimizer == "SNOPT":
    prob.driver.opt_settings = {
        "Major feasibility tolerance": 1.0e-6,
        "Major optimality tolerance": 1.0e-6,
        "Minor feasibility tolerance": 1.0e-6,
        "Verify level": -1,
        "Function precision": 1.0e-6,
        "Major iterations limit": 500,
        "Linesearch tolerance": 0.999,
        "Hessian updates": 50,
        "Nonderivative linesearch": None,
        "Print file": "opt_SNOPT_print.txt",
        "Summary file": "opt_SNOPT_summary.txt",
    }
elif args.optimizer == "IPOPT":
    prob.driver.opt_settings = {
        "tol": 1.0e-5,
        "constr_viol_tol": 1.0e-5,
        "max_iter": 500,
        "print_level": 5,
        "output_file": "opt_IPOPT.txt",
        "mu_strategy": "adaptive",
        "limited_memory_max_history": 10,
        "nlp_scaling_method": "none",
        "alpha_for_y": "full",
        "recalc_y": "yes",
    }
elif args.optimizer == "ParOpt":
    prob.driver.opt_settings = {
    "algorithm": "mma",
    "mma_output_file": "paropt.mma",  # MMA output file name
    "output_file": "paropt.out",  # Interior point output file
    "mma_max_iterations": nContinuation,  # Maximum number of iterations for MMA
    "mma_infeas_tol": 1e-6,  # Feasibility tolerance for MMA
    "mma_l1_tol": 1e-6,  # l1 tolerance on the on the KKT conditions for MMA
    "mma_linfty_tol" : 1e-6,  # l-infinity tolerance on the KKT conditions for MMA
    "max_major_iters": 500,  # Max iterations for each subproblem
    "abs_res_tol": 1e-6,  # Tolerance for each subproblem
    "mma_move_limit": 0.1,
    "starting_point_strategy": "affine_step",  # IP initialization strategy
    "barrier_strategy": "mehrotra",  # IP barrier strategy
    "use_line_search": True,
    }
elif args.optimizer == "SLSQP":
    prob.driver.opt_settings = {
        "ACC": 1.0e-5,
        "MAXIT": 100,
        "IFILE": "opt_SLSQP.txt",
    }
else:
    print("optimizer arg not valid!")
    exit(1)

prob.driver.options["debug_print"] = ["nl_cons", "objs", "desvars"]
prob.driver.options["print_opt_prob"] = True
prob.driver.hist_file = "OptView.hst"


if args.task == "run_driver":
    # run the optimization
    prob.run_driver()
elif args.task == "run_model":
    # just run the primal once
    prob.run_model()
elif args.task == "compute_totals":
    # just run the primal and adjoint once
    prob.run_model()
    totals = prob.compute_totals()
    if MPI.COMM_WORLD.rank == 0:
        print(totals)
elif args.task == "check_totals":
    # verify the total derivatives against the finite-difference
    prob.run_model()
    prob.check_totals(compact_print=False, step=1e-2, form="central", step_calc="abs")
# h	relErr
# 1.00E-01	2.39E-02
# 1.00E-02	5.09E-03
# 1.00E-03	2.27E-02
# 1.00E-04	5.50E-01

else:
    print("task arg not found!")
    exit(1)
