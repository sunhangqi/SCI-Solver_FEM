#include <stdio.h>
#include <iostream>
#include <pthread.h>
#include <signal.h>
#include <exception>

#include <amg_config.h>
#include <types.h>
#include <TriMesh.h>
#include <tetmesh.h>
#include <cutil.h>
#include <FEM/FEM2D.h>
#include <FEM/FEM3D.h>
#include <timer.h>
#include <amg.h>

/*

#include <cusp/io/matrix_market.h>
#include <cusp/print.h>
#include <cusp/gallery/poisson.h>
#include <fstream>


*/

using namespace std;


int setup_solver(AMG_Config& cfg, TriMesh* meshPtr, TetMesh* tetmeshPtr,
		         FEM2D* fem2d, FEM3D* fem3d, Matrix_d* A,
		         Vector_d_CG* x_d, Vector_d_CG* b_d, bool verbose)
{
    srand48(0);

    if( verbose ) {
        int deviceCount;
        cudaGetDeviceCount(&deviceCount);
        int device;
        for (device = 0; device < deviceCount; ++device) {
            cudaDeviceProp deviceProp;
            cudaGetDeviceProperties(&deviceProp, device);
            size_t totalMemory = deviceProp.totalGlobalMem;
            int totalMB = totalMemory / 1000000;
            printf("Device %d (%s) has compute capability %d.%d, %d regs per block, and %dMb global memory.\n",
                    device, deviceProp.name, deviceProp.major, deviceProp.minor, deviceProp.regsPerBlock, totalMB);
        }
    }

    int cudaDeviceNumber = cfg.getParameter("cuda_device_num");
    cudaSetDevice(cudaDeviceNumber);
    if (cudaDeviceReset() != cudaSuccess) {
        exit(0);
     	string error = "CUDA device " + cudaDeviceNumber + " is not available on this system.";
       	throw invalid_argument(error);
    } else if( verbose ) {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, 1);
    }

    double Assemblestart, Assemblestop;
    double neednbstart, neednbstop;
    double prepAssemstart, prepAssemstop;

    int meshType = getParameter("mesh_type");
    if( meshType == 0 ) {
    	//Triangular mesh
        meshPtr->rescale(4.0);
        neednbstart = CLOCK();
        meshPtr->need_neighbors();
        meshPtr->need_meshquality();
        neednbstop = CLOCK();
        Matrix_ell_d_CG Aell_d;
        Vector_d_CG RHS(meshPtr->vertices.size(), 0.0);

        prepAssemstart = CLOCK();
        trimesh2ell<Matrix_ell_d_CG > (meshPtr, Aell_d);
        cudaThreadSynchronize();

        prepAssemstop = CLOCK();
        Assemblestart = CLOCK();
        fem2d = FEM2D(meshPtr);

        fem2d->assemble(meshPtr, Aell_d, RHS);

        cudaThreadSynchronize();
        Assemblestop = CLOCK();

        A = Aell_d;
        Aell_d.resize(0, 0, 0, 0);
    } else if( meshType == 1 ) {
    	//Tet mesh
        tetmeshPtr->need_neighbors();
        tetmeshPtr->need_meshquality();
        tetmeshPtr->rescale(1.0);

        Matrix_ell_d_CG Aell_d;
        Matrix_ell_h_CG Aell_h;
        Vector_d_CG RHS(tetmeshPtr->vertices.size(), 0.0);

        prepAssemstart = CLOCK();
        tetmesh2ell<Matrix_ell_d_CG > (tetmeshPtr, Aell_d);
        cudaThreadSynchronize();
        prepAssemstop = CLOCK();

        fem3d = FEM3D(tetmeshPtr);
        Assemblestart = CLOCK();
        fem3d->assemble(tetmeshPtr, Aell_d, RHS, true);
        cudaThreadSynchronize();
        Assemblestop = CLOCK();
        //            cusp::print(Aell_d);
        A = Aell_d;
        Aell_d.resize(0, 0, 0, 0);
    }

    if (A.num_rows == 0) {
    	if( verbose ) {
    		printf("Error no matrix specified\n");
    	}
    	string error = "Error no matrix specified";
    	throw invalid_argument(error);
    }
    Vector_h_CG b(A.num_rows, 1.0);
    Vector_h_CG x(A.num_rows, 0.0); //initial
    x_d = x;
    b_d = b;

    if( verbose ) {
        cfg.printAMGConfig();
    }
    AMG<Matrix_h, Vector_h> amg(*cfg);
    amg.setup(A, meshPtr, tetmeshPtr);
    if( verbose ) {
    	amg.printGridStatistics();
    }
    amg.solve(b_d, x_d);
}
