
/*************************************************************************/
/*                                                                       */
/*  Copyright (c) 1994 Stanford University                               */
/*                                                                       */
/*  All rights reserved.                                                 */
/*                                                                       */
/*  Permission is given to use, copy, and modify this software for any   */
/*  non-commercial purpose as long as this copyright notice is not       */
/*  removed.  All other uses, including redistribution in whole or in    */
/*  part, are forbidden without prior written permission.                */
/*                                                                       */
/*  This software is provided with absolutely no warranty and no         */
/*  support.                                                             */
/*                                                                       */
/*************************************************************************/

/*************************************************************************/
/*                                                                       */
/*  Perform 1D fast Fourier transform using six-step FFT method          */
/*                                                                       */
/*  1) Performs staggered, blocked transposes for cache-line reuse       */
/*  2) Roots of unity rearranged and distributed for only local          */
/*     accesses during application of roots of unity                     */
/*  3) Small set of roots of unity elements replicated locally for       */
/*     1D FFTs (less than root N elements replicated at each node)       */
/*  4) Matrix data structures are padded to reduce cache mapping         */
/*     conflicts                                                         */
/*                                                                       */
/*  Command line options:                                                */
/*                                                                       */
/*  -mM : M = even integer; 2**M total complex data points transformed.  */
/*  -pP : P = number of processors; Must be a power of 2.                */
/*  -nN : N = number of cache lines.                                     */
/*  -lL : L = Log base 2 of cache line length in bytes.                  */
/*  -s  : Print individual processor timing statistics.                  */
/*  -t  : Perform FFT and inverse FFT.  Test output by comparing the     */
/*        integral of the original data to the integral of the data      */
/*        that results from performing the FFT and inverse FFT.          */
/*  -o  : Print out complex data points.                                 */
/*  -h  : Print out command line options.                                */
/*                                                                       */
/*  Note: This version works under both the FORK and SPROC models        */
/*                                                                       */
/*************************************************************************/

#include <stdio.h>
#include <math.h>
#include <sys/time.h>
#include <sys/times.h>
#include <unistd.h>
#include <getopt.h>
#include <assert.h>

#define PAGE_SIZE                  0
#define NUM_CACHE_LINES        65536 
#define LOG2_LINE_SIZE             4
#define PI                         3.1416
#define DEFAULT_M                 10
#define DEFAULT_P                  1
#define DEFAULT_ACCEL              1


#include <stdlib.h>
#include <time.h>

#include <ppu_intrinsics.h>

#include "tpc_common.h"
#include "tpc_ppe.h"
#include "fftsp.h"

#define SWAP(a,b) {float tmp; tmp=a; a=b; b=tmp;}


double fft_get_time(void)
{
  return (double)__mftb();
    /*struct timeval tp;
    int rtn;
    //rtn=gettimeofday(&tp, NULL);

    //return ((double)tp.tv_sec+(1.e-6)*tp.tv_usec);

	struct tms tbuf;
	return (double)times(&tbuf) / (double)sysconf(_SC_CLK_TCK);*/
}


struct GlobalMemory {
  int id;
  int (idlock);
  int (start);
  double *transtimes;
  double *totaltimes;
  double starttime;
  double finishtime;
  double initdonetime;
} *Global;


int ACCEL = DEFAULT_ACCEL; // @@@ tzenakis: ACEEL is the number of
			   // accelerators
int P = DEFAULT_P;
int M = DEFAULT_M;
int N;                  /* N = 2^M                                */
int rootN;              /* rootN = N^1/2                          */
float *x;              /* x is the original time-domain data     */
float *trans;          /* trans is used as scratch space         */
float *umain;          /* umain is roots of unity for 1D FFTs    */
float *umain2;         /* umain2 is entire roots of unity matrix */
int test_result = 0;
int doprint = 0;
int dostats = 0;
double transtime = 0;
double transtime2 = 0;
double avgtranstime = 0;
double avgcomptime = 0;
double transstart = 0;
double transend = 0;
double maxtotal=0;
double mintotal=0;
double maxfrac=0;
double minfrac=0;
double avgfractime=0;
int orig_num_lines = NUM_CACHE_LINES;     /* number of cache lines */
int num_cache_lines = NUM_CACHE_LINES;    /* number of cache lines */
int log2_line_size = LOG2_LINE_SIZE;
int line_size;
int rowsperproc;
float ck1;
float ck3;                        /* checksums for testing answer */
int pad_length;

void SlaveStart();
float TouchArray(float *,float *,float *,float *,int,int,int,int);
void FFT1D(int,int,int,float *,float *,float *, float *,float *,int,double *,int,
	   int,int,int,int,int,int,struct GlobalMemory *);
float CheckSum();
int log_2(int);
void printerr(char *);



void InitX(N, x)
int N;
float *x;
{
  int i,j,k;

  srand48(0);
  for (j=0; j<rootN; j++) {
    k = j * (rootN + pad_length);
    for (i=0;i<rootN;i++) {
      x[2*(k+i)] = drand48();
      x[2*(k+i)+1] = drand48();
    }
  }
}


void InitU(N, u)
int N;
float *u;
{
  int q; 
  int j; 
  int base; 
  int n1;

  for (q=0; 1<<q<N; q++) {  
    n1 = 1<<q;
    base = n1-1;
    for (j=0; j<n1; j++) {
      if (base+j > rootN-1) { 
	return;
      }
      u[2*(base+j)] = cos(2.0*PI*j/(2*n1));
      u[2*(base+j)+1] = -sin(2.0*PI*j/(2*n1));
    }
  }
}


void InitU2(N, u, n1)
int N;
float *u;
int n1;
{
  int i,j,k; 

  for (j=0; j<n1; j++) {  
    k = j*(rootN+pad_length);
    for (i=0; i<n1; i++) {  
      u[2*(k+i)] = cos(2.0*PI*i*j/(N));
      u[2*(k+i)+1] = -sin(2.0*PI*i*j/(N));
    }
  }
}


void PrintArray(N, x)
int N;
float *x;
{
  int i, j, k;

  for (i=0; i<rootN; i++) {
    k = i*(rootN+pad_length);
    for (j=0; j<rootN; j++) {
      printf(" %4.2f %4.2f", x[2*(k+j)], x[2*(k+j)+1]);
      if (i*rootN+j != N-1) {
        printf(",");
      }
      if ((i*rootN+j+1) % 8 == 0) {
        printf("\n");
      }
    }
  }
  printf("\n");
  printf("\n");
}





int main(argc, argv)
int argc;
char **argv;
{
  int i; 
  //int j; 
  int c;
  extern char *optarg;
  int m1;
  int factor;
  //int pages;
  double start;

  {(start) = fft_get_time();};

  while ((c = getopt(argc, argv, "p:a:m:n:l:stoh")) != -1) {
    switch(c) {
      case 'p': P = atoi(optarg); 
                if (P < 1) {
                  printerr("P must be >= 1\n");
                  exit(-1);
                }
                if (log_2(P) == -1) {
                  printerr("P must be a power of 2\n");
                  exit(-1);
                }
	        break;  
      case 'm': M = atoi(optarg); 
                m1 = M/2;
                if (2*m1 != M) {
                  printerr("M must be even\n");
                  exit(-1);
                }
	        break;  
      case 'a': ACCEL = atoi(optarg); 
                if (ACCEL < 1) {
                  printerr("Wrong number of accelerators\n");
                  exit(-1);
                }
	        break;  
      case 'n': num_cache_lines = atoi(optarg); 
                orig_num_lines = num_cache_lines;
                if (num_cache_lines < 1) {
                  printerr("Number of cache lines must be >= 1\n");
                  exit(-1);
                }
	        break;  
      case 'l': log2_line_size = atoi(optarg); 
                if (log2_line_size < 0) {
                  printerr("Log base 2 of cache line length in bytes must be >= 0\n");
                  exit(-1);
                }
	        break;  
      case 's': dostats = !dostats; 
	        break;
      case 't': test_result = !test_result; 
	        break;
      case 'o': doprint = !doprint; 
	        break;
      case 'h': printf("Usage: FFT <options>\n\n");
                printf("options:\n");
                printf("  -mM : M = even integer; 2**M total complex data points transformed.\n");
                printf("  -pP : P = number of processors; Must be a power of 2.\n");
                printf("  -nN : N = number of cache lines.\n");
                printf("  -lL : L = Log base 2 of cache line length in bytes.\n");
                printf("  -s  : Print individual processor timing statistics.\n");
                printf("  -t  : Perform FFT and inverse FFT.  Test output by comparing the\n");
                printf("        integral of the original data to the integral of the data that\n");
                printf("        results from performing the FFT and inverse FFT.\n");
                printf("  -o  : Print out complex data points.\n");
                printf("  -h  : Print out command line options.\n\n");
                printf("Default: FFT -m%1d -p%1d -n%1d -l%1d\n",
                       DEFAULT_M,DEFAULT_P,NUM_CACHE_LINES,LOG2_LINE_SIZE);
		exit(0);
	        break;
    }
  }

  {;};

  N = 1<<M;
  rootN = 1<<(M/2);
  rowsperproc = rootN/P;
  if (rowsperproc == 0) {
    printerr("Matrix not large enough. 2**(M/2) must be >= P\n");
    exit(-1);
  }

  line_size = 1 << log2_line_size;
  if (line_size < 2*sizeof(float)) {
    printf("WARNING: Each element is a complex float (%d bytes)\n",2*sizeof(float));
    printf("  => Less than one element per cache line\n");
    printf("     Computing transpose blocking factor\n");
    factor = (2*sizeof(float)) / line_size;
    num_cache_lines = orig_num_lines / factor;
  }


  // @@@ tzenakis
  // We don't need any pading
  /*
  if (line_size <= 2*sizeof(float)) {
    pad_length = 1;
  } else {
    pad_length = line_size / (2*sizeof(float));
  }

  if (rowsperproc * rootN * 2 * sizeof(float) >= PAGE_SIZE) {
    pages = (2 * pad_length * sizeof(float) * rowsperproc) / PAGE_SIZE;
    if (pages * PAGE_SIZE != 2 * pad_length * sizeof(float) * rowsperproc) {
      pages ++;
    }
    pad_length = (pages * PAGE_SIZE) / (2 * sizeof(float) * rowsperproc);
  } else {
    pad_length = (PAGE_SIZE - (rowsperproc * rootN * 2 * sizeof(float))) /

                 (2 * sizeof(float) * rowsperproc);
    if (pad_length * (2 * sizeof(float) * rowsperproc) !=
        (PAGE_SIZE - (rowsperproc * rootN * 2 * sizeof(float)))) {
      printerr("Padding algorithm unsuccessful\n");
      exit(-1);
    }
  }
  */

  // @@@ tzenakis
  pad_length = 0;

  // N is the total elements
  // rootN is the number of elements per row
  Global = (struct GlobalMemory *) tpc_malloc(sizeof(struct GlobalMemory));;
  x = (float *) tpc_malloc(2*(N+rootN*pad_length)*sizeof(float)+PAGE_SIZE);;
  trans = (float *) tpc_malloc(2*(N+rootN*pad_length)*sizeof(float)+PAGE_SIZE);;
  umain = (float *) tpc_malloc(2*rootN*sizeof(float));;  
  umain2 = (float *) tpc_malloc(2*(N+rootN*pad_length)*sizeof(float)+PAGE_SIZE);;

  Global->transtimes = (double *) tpc_malloc(P*sizeof(double));;  
  Global->totaltimes = (double *) tpc_malloc(P*sizeof(double));;  
  if (Global == NULL) {
    printerr("Could not tpc_malloc memory for Global\n");
    exit(-1);
  } else if (x == NULL) {
    printerr("Could not tpc_malloc memory for x\n");
    exit(-1);
  } else if (trans == NULL) {
    printerr("Could not tpc_malloc memory for trans\n");
    exit(-1);
  } else if (umain == NULL) {
    printerr("Could not tpc_malloc memory for umain\n");
    exit(-1);
  } else if (umain2 == NULL) {
    printerr("Could not tpc_malloc memory for umain2\n");
    exit(-1);
  }

  // @@@ tzenakis
  // We don't care about pages anymore. PAGE_SIZE is set to zero
  /*
  x = (float *)(((unsigned) x) + PAGE_SIZE - ((unsigned) x) % PAGE_SIZE);
  trans = (float *)(((unsigned) trans) + PAGE_SIZE - ((unsigned) trans) % PAGE_SIZE);
  umain2 = (float *)(((unsigned) umain2) + PAGE_SIZE - ((unsigned) umain2) % PAGE_SIZE);
  */

/* In order to optimize data distribution, the data structures x, trans, 
   and umain2 have been aligned so that each begins on a page boundary. 
   This ensures that the amount of padding calculated by the program is 
   such that each processor's partition ends on a page boundary, thus 
   ensuring that all data from these structures that are needed by a 
   processor can be allocated to its local memory */

/* POSSIBLE ENHANCEMENT:  Here is where one might distribute the x,
   trans, and umain2 data structures across physically distributed 
   memories as desired.
   
   One way to place data is as follows:

   double *base;
   int i;

   i = ((N/P)+(rootN/P)*pad_length)*2;
   base = &(x[0]);
   for (j=0;j<P;j++) {
    Place all addresses x such that (base <= x < base+i) on node j
    base += i;
   }

   The trans and umain2 data structures can be placed in a similar manner.

   */

  printf("\n");
  printf("FFT with Blocking Transpose\n");
  printf("   %d Complex Doubles\n",N);
  printf("   %d Processors / %d Accelerators\n", P, ACCEL);
  if (num_cache_lines != orig_num_lines) {
    printf("   %d Cache lines\n",orig_num_lines);
    printf("   %d Cache lines for blocking transpose\n",num_cache_lines);
  } else {
    printf("   %d Cache lines\n",num_cache_lines);
  }
  printf("   %d Byte line size\n",(1 << log2_line_size));
  printf("   %d Bytes per page (%d pad_length)\n",PAGE_SIZE, pad_length);
  printf("\n");

  {;};
  {;};
  Global->id = 0;
  InitX(N, x);                  /* place random values in x */

  if (test_result) {
    ck1 = CheckSum(N, x);
  }
  if (doprint) {
    printf("Original data values:\n");
    PrintArray(N, x);
  }

  InitU(N,umain);               /* initialize u arrays*/
  InitU2(N,umain2,rootN);

  tpc_init(ACCEL);

  /* fire off P processes */
  for (i=1; i<P; i++) {
    {fprintf(stderr, "No more processors -- this is a uniprocessor version!\n"); exit(-1);};
  }
  SlaveStart();

  {;}

  if (doprint) {
    if (test_result) {
      printf("Data values after inverse FFT:\n");
    } else {
      printf("Data values after FFT:\n");
    }
    PrintArray(N, x);
  }

  transtime = Global->transtimes[0];
  printf("\n");
  printf("                 PROCESS STATISTICS\n");
  printf("            Computation      Transpose     Transpose\n");
  printf(" Proc          Time            Time        Fraction\n");
  printf("    0        %10lf     %10lf      %8.5lf\n",
         Global->totaltimes[0],Global->transtimes[0],
         ((double)Global->transtimes[0])/Global->totaltimes[0]);
  if (dostats) {
    transtime2 = Global->transtimes[0];
    avgtranstime = Global->transtimes[0];
    avgcomptime = Global->totaltimes[0];
    maxtotal = Global->totaltimes[0];
    mintotal = Global->totaltimes[0];
    maxfrac = ((double)Global->transtimes[0])/Global->totaltimes[0];
    minfrac = ((double)Global->transtimes[0])/Global->totaltimes[0];
    avgfractime = ((double)Global->transtimes[0])/Global->totaltimes[0];
    for (i=1;i<P;i++) {
      if (Global->transtimes[i] > transtime) {
        transtime = Global->transtimes[i];
      }
      if (Global->transtimes[i] < transtime2) {
        transtime2 = Global->transtimes[i];
      }
      if (Global->totaltimes[i] > maxtotal) {
        maxtotal = Global->totaltimes[i];
      }
      if (Global->totaltimes[i] < mintotal) {
        mintotal = Global->totaltimes[i];
      }
      if (((double)Global->transtimes[i])/Global->totaltimes[i] > maxfrac) {
        maxfrac = ((double)Global->transtimes[i])/Global->totaltimes[i];
      }
      if (((double)Global->transtimes[i])/Global->totaltimes[i] < minfrac) {
        minfrac = ((double)Global->transtimes[i])/Global->totaltimes[i];
      }
      printf("  %3d        %10lf     %10lf      %8.5lf\n",
             i,Global->totaltimes[i],Global->transtimes[i],
             ((double)Global->transtimes[i])/Global->totaltimes[i]);
      avgtranstime += Global->transtimes[i];
      avgcomptime += Global->totaltimes[i];
      avgfractime += ((double)Global->transtimes[i])/Global->totaltimes[i];
    }
    printf("  Avg        %10f     %10f      %8.5f\n",
           ((double) avgcomptime)/P,((double) avgtranstime)/P,avgfractime/P);
    printf("  Max        %10f     %10f      %8.5f\n",
	   maxtotal,transtime,maxfrac);
    printf("  Min        %10f     %10f      %8.5f\n",
	   mintotal,transtime2,minfrac);
  }
  Global->starttime = start;
  printf("\n");
  printf("                 TIMING INFORMATION\n");
  printf("Start time                        : %16lf\n",
	  Global->starttime);
  printf("Initialization finish time        : %16lf\n",
	  Global->initdonetime);
  printf("Overall finish time               : %16lf\n",
	  Global->finishtime);
  printf("Total time with initialization    : %16lf\n",
	  Global->finishtime-Global->starttime);
  printf("Total time without initialization : %16lf\n",
	  Global->finishtime-Global->initdonetime);
  printf("Overall transpose time            : %16lf\n",
         transtime);
  printf("Overall transpose fraction        : %16.5lf\n",
         ((double) transtime)/(Global->finishtime-Global->initdonetime));
  printf("\n");

  if (test_result) {
    ck3 = CheckSum(N, x);
    printf("              INVERSE FFT TEST RESULTS\n");
    printf("Checksum difference is %.3f (%.3f, %.3f)\n",
	   ck1-ck3, ck1, ck3);
    if (fabs(ck1-ck3) < 0.001) {
      printf("TEST PASSED\n");
    } else {
      printf("TEST FAILED\n");
    }
  }

  tpc_print_stats(stdout);
  tpc_shutdown();
  {exit(0);};
  return 0;
}


void SlaveStart()
{
  int i;
  int MyNum;
  float *upriv;
  float *upriv_vec;
  double initdone; 
  double finish; 
  double l_transtime=0;
  int MyFirst; 
  int MyLast;

  initdone = Global->starttime;
  {;};
    MyNum = Global->id;
    Global->id++;
  {;}; 

/* POSSIBLE ENHANCEMENT:  Here is where one might pin processes to
   processors to avoid migration */

  {;};


  // @@@ tzenakis
  // upriv_vec is the same as original upriv but shifted to the left by one
  // complex element. This modification is needed for the vectorized single
  // presicion version of FFT to avoid unaligned vector loads in FFT1DOnce().

  upriv = (float *) tpc_malloc(2*(rootN-1)*sizeof(float));
  upriv_vec = (float *) tpc_malloc(2*(rootN)*sizeof(float));
  if (upriv == NULL || upriv_vec == NULL) {
    fprintf(stderr,"Proc %d could not tpc_malloc memory for upriv\n",MyNum);
    exit(-1);
  }
  for (i=0;i<2*(rootN-1);i++) {
    upriv[i] = umain[i];
    upriv_vec[i+2] = umain[i];
  }   

  MyFirst = rootN*MyNum/P;
  MyLast = rootN*(MyNum+1)/P;

  TouchArray(x, trans, umain2, upriv, N, MyNum, MyFirst, MyLast);

  // @@@ tzenakis
  // Touch data second time to touch and upriv_vec.
  TouchArray(x, trans, umain2, upriv_vec, N, MyNum, MyFirst, MyLast);

  {;};

/* POSSIBLE ENHANCEMENT:  Here is where one might reset the
   statistics that one is measuring about the parallel execution */

  if ((MyNum == 0) || (dostats)) {
    {(initdone) = fft_get_time();};
  }

  /* perform forward FFT */
  FFT1D(1, M, N, x, trans, upriv, upriv_vec, umain2, MyNum, &l_transtime, MyFirst, 
	MyLast, pad_length, P, test_result, doprint, dostats, Global);

  /* perform backward FFT */
  if (test_result) {
    FFT1D(-1, M, N, x, trans, upriv, upriv_vec, umain2, MyNum, &l_transtime, MyFirst, 
	  MyLast, pad_length, P, test_result, doprint, dostats, Global);
  }  

  if ((MyNum == 0) || (dostats)) {
    {(finish) = fft_get_time();};
    Global->transtimes[MyNum] = l_transtime;
    Global->totaltimes[MyNum] = finish-initdone;
  }
  if (MyNum == 0) {
    Global->finishtime = finish;
    Global->initdonetime = initdone;
  }
}


float TouchArray(x, scratch, u, upriv, N, MyNum, MyFirst, MyLast)

float *x; 
float *scratch; 
float *u; 
float *upriv;
int N; 
int MyNum;
int MyFirst;
int MyLast;

{
  int i,j,k;
  float tot = 0.0;

  /* touch my data */
  for (j=0;j<2*(rootN-1);j++) {
    tot += upriv[j];
  }   
  for (j=MyFirst; j<MyLast; j++) {
    k = j * (rootN + pad_length);
    for (i=0;i<rootN;i++) {
      tot += x[2*(k+i)] + x[2*(k+i)+1] + 
             scratch[2*(k+i)] + scratch[2*(k+i)+1] +
	     u[2*(k+i)] + u[2*(k+i)+1];
    }
  }  
  return tot;
}


float CheckSum(N, x)

int N;
float *x;

{
  int i,j,k;
  float cks;

  cks = 0.0;
  for (j=0; j<rootN; j++) {
    k = j * (rootN + pad_length);
    for (i=0;i<rootN;i++) {
      cks += x[2*(k+i)] + x[2*(k+i)+1];
    }
  }

  return(cks);
}






void TwiddleOneCol(direction, n1, N, j, u, x, pad_length)
int direction; 
int n1;
int N;
int j;
float *u;
float *x;
int pad_length;
{
  int i;
  float omega_r; 
  float omega_c; 
  float x_r; 
  float x_c;
/*  double r1;
  double c1;
  double r2;
  double c2;*/

  for (i=0; i<n1; i++) {
    omega_r = u[2*(j*(n1+pad_length)+i)];
    omega_c = direction*u[2*(j*(n1+pad_length)+i)+1];  
    x_r = x[2*i]; 
    x_c = x[2*i+1];
    x[2*i] = omega_r*x_r - omega_c*x_c;
    x[2*i+1] = omega_r*x_c + omega_c*x_r;
  }
}


void Scale(n1, N, x)
int n1; 
int N;
float *x;
{
  int i;

  for (i=0; i<n1; i++) {
    x[2*i] /= N;
    x[2*i+1] /= N;
  }
}



void Transpose(n1, src, dest, MyNum, MyFirst, MyLast, pad_length)
int n1;
float *src; 
float *dest;
int MyNum;
int MyFirst;
int MyLast;
int pad_length;
{
  int i; 
  int j; 
  int k; 
  int l; 
  int m;
  int blksize;
  int numblks;
  int firstfirst;
  int h_off;
  int v_off;
  int v;
  int h;
  int n1p;
  int row_count;

  blksize = MyLast-MyFirst;
  numblks = (2*blksize)/num_cache_lines;
  if (numblks * num_cache_lines != 2 * blksize) {
    numblks ++;
  }
  blksize = blksize / numblks;
  firstfirst = MyFirst;
  row_count = n1/P;
  n1p = n1+pad_length;
  for (l=MyNum+1;l<P;l++) {
    v_off = l*row_count;
    for (k=0; k<numblks; k++) {
      h_off = firstfirst;
      for (m=0; m<numblks; m++) {
        for (i=0; i<blksize; i++) {
	  v = v_off + i;
          for (j=0; j<blksize; j++) {
	    h = h_off + j;
            dest[2*(h*n1p+v)] = src[2*(v*n1p+h)];
            dest[2*(h*n1p+v)+1] = src[2*(v*n1p+h)+1];
          }
        }
	h_off += blksize;
      }
      v_off+=blksize;
    }
  }

  for (l=0;l<MyNum;l++) {
    v_off = l*row_count;
    for (k=0; k<numblks; k++) {
      h_off = firstfirst;
      for (m=0; m<numblks; m++) {
        for (i=0; i<blksize; i++) {
	  v = v_off + i;
          for (j=0; j<blksize; j++) {
            h = h_off + j;
            dest[2*(h*n1p+v)] = src[2*(v*n1p+h)];
            dest[2*(h*n1p+v)+1] = src[2*(v*n1p+h)+1];
          }
        }
	h_off += blksize;
      }
      v_off+=blksize;
    }
  }

  v_off = MyNum*row_count;
  for (k=0; k<numblks; k++) {
    h_off = firstfirst;
    for (m=0; m<numblks; m++) {
      for (i=0; i<blksize; i++) {
        v = v_off + i;
        for (j=0; j<blksize; j++) {
          h = h_off + j;
          dest[2*(h*n1p+v)] = src[2*(v*n1p+h)];
          dest[2*(h*n1p+v)+1] = src[2*(v*n1p+h)+1];
	}
      }
      h_off += blksize;
    }
    v_off+=blksize;
  }
}



void CopyColumn(n1, src, dest)
int n1;
float *src; 
float *dest;
{
  int i;

  for (i=0; i<n1; i++) {
    dest[2*i] = src[2*i];
    dest[2*i+1] = src[2*i+1];
  }
}


int BitReverse(M, k)
int M; 
int k;
{
  int i; 
  int j; 
  int tmp;

  j = 0;
  tmp = k;
  for (i=0; i<M; i++) {
    j = 2*j + (tmp&0x1);
    tmp = tmp>>1;
  }
  return(j);
}



void Reverse(N, M, x)
int N; 
int M;
float *x;
{
  int j, k;

  printf("\nReverse %d, %d\n", N, M);

  for (k=0; k<N; k++) {
    j = BitReverse(M, k);
    printf("%d, %d\n", k, j);
    if (j > k) {
      //printf("  SWAP %d %d\n", j, k);
      //printf("MYSWAP %d %d\n", , k);
      SWAP(x[2*j], x[2*k]);
      SWAP(x[2*j+1], x[2*k+1]);
    }
  }
}





void FFT1DOnce(direction, M, N, u, x)
int direction; 
int M; 
int N;
float *u; 
float *x;
{
  int j; 
  int k; 
  int q; 
  int L; 
  int r; 
  int Lstar;
  float *u1; 
  float *x1; 
  float *x2;
  float omega_r; 
  float omega_c; 
  float tau_r; 
  float tau_c; 
  float x_r; 
  float x_c;

  Reverse(N, M, x);

  //printf("\nFFT1Donce %d %d\n", M, N);
  for (q=1; q<=M; q++) {
    L = 1<<q; r = N/L; Lstar = L/2;
    u1 = &u[2*(Lstar-1)];
    //printf("q=%d (u1:%d)\n", q, (Lstar));
    for (k=0; k<r; k++) {
      //printf("  k=%d, (%d,%d)\n", k, (k*L),(k*L+Lstar));
      x1 = &x[2*(k*L)];
      x2 = &x[2*(k*L+Lstar)];
      for (j=0; j<Lstar; j++) {
        //printf("    j=%d\n", j);
	omega_r = u1[2*j]; 
        omega_c = direction*u1[2*j+1];
	x_r = x2[2*j]; 
        x_c = x2[2*j+1];
	tau_r = omega_r*x_r - omega_c*x_c;
	tau_c = omega_r*x_c + omega_c*x_r;
	x_r = x1[2*j]; 
        x_c = x1[2*j+1];
	x2[2*j] = x_r - tau_r;
	x2[2*j+1] = x_c - tau_c;
	x1[2*j] = x_r + tau_r;
	x1[2*j+1] = x_c + tau_c;
      }
    }
  }
}




void printerr(s)
char *s;
{
  fprintf(stderr,"ERROR: %s\n",s);
}


int log_2(number)
int number;
{
  int cumulative = 1;
  int out = 0;
  int done = 0;

  while ((cumulative < number) && (!done) && (out < 50)) {
    if (cumulative == number) {
      done = 1;
    } else {
      cumulative = cumulative * 2;
      out ++;
    }
  }

  if (cumulative == number) {
    return(out);
  } else {
    return(-1);
  }
}





void FFT1D(direction, M, N, x, scratch, upriv, upriv_vec, umain2, MyNum, l_transtime, 
           MyFirst, MyLast, pad_length, P, test_result, doprint, dostats, 
	   Global)
int direction; 
int M; 
int N; 
double *l_transtime;
float *x; 
float *upriv;
float *upriv_vec;
float *scratch;
float *umain2; 
int MyFirst;
int MyLast;
int pad_length;
int P;
int test_result;
int doprint;
int dostats;
struct GlobalMemory *Global;
{
  int j;
  int m1; 
  int n1;
  double clocktime1;
  double clocktime2;
  struct FFTsteps23args *s23args, *s5args;
  int bytes_per_row;
  int rows_per_task1;
  int rows_per_task2;
  int trasn_block;

  m1 = M/2;
  n1 = 1<<m1;  // n1 is the number of (complex floats) elements per row.

  bytes_per_row = 2*n1*sizeof(float);
  
  rows_per_task1 = 1;
  rows_per_task2 = 1;
  trasn_block=32;

  //fprintf(stdout, "N1 = %d\n", n1);

  s23args = tpc_malloc(sizeof(struct FFTsteps23args));
  s5args = tpc_malloc(sizeof(struct FFTsteps23args));
  assert(s23args!=NULL && s5args!=NULL);

  {;};	// BARRIER ============================================================

  if ((MyNum == 0) || (dostats)) {
    {(clocktime1) = fft_get_time();};
  }

  /* transpose from x into scratch */
  //Transpose(n1, x, scratch, MyNum, MyFirst, MyLast, pad_length);
  tpc_traspose(x, n1, trasn_block);
  
  if ((MyNum == 0) || (dostats)) {
    {(clocktime2) = fft_get_time();};
    *l_transtime += (clocktime2-clocktime1);
  }

  /* do n1 1D FFTs on columns */
  /*for (j=MyFirst; j<MyLast; j++) {
    FFT1DOnce(direction, m1, n1, upriv, &scratch[2*j*(n1+pad_length)]);
    TwiddleOneCol(direction, n1, N, j, umain2, &scratch[2*j*(n1+pad_length)],
		  pad_length);
  }*/
  s23args->m1 = m1;
  s23args->n1 = n1;
  s23args->N = N;
  s23args->pad_length = pad_length;
  s23args->direction = direction;
  s23args->rows = rows_per_task1;
  for (j=MyFirst; j<MyLast; j+=rows_per_task1) {
    tpc_call( 0, 4,
	&x[2*j*(n1+pad_length)], bytes_per_row*rows_per_task1, TPC_INOUT_ARG,
	upriv_vec, bytes_per_row, TPC_IN_ARG,
	&umain2[2*j*(n1+pad_length)], bytes_per_row*rows_per_task1, TPC_IN_ARG,
	s23args, sizeof(struct FFTsteps23args), TPC_IN_ARG );
  }
  tpc_wait_all();

  {;};	// BARRIER ============================================================

  if ((MyNum == 0) || (dostats)) {
    {(clocktime1) = fft_get_time();};
  }
  /* transpose */
  //Transpose(n1, scratch, x, MyNum, MyFirst, MyLast, pad_length);
  tpc_traspose(x, n1, trasn_block);

  if ((MyNum == 0) || (dostats)) {
    {(clocktime2) = fft_get_time();};
    *l_transtime += (clocktime2-clocktime1);
  }

  /* do n1 1D FFTs on columns again */
  /*for (j=MyFirst; j<MyLast; j++) {
    FFT1DOnce(direction, m1, n1, upriv, &x[2*j*(n1+pad_length)]);
    if (direction == -1)
      Scale(n1, N, &x[2*j*(n1+pad_length)]);
  }*/
  s5args->m1 = m1;
  s5args->n1 = n1;
  s5args->N = N;
  s5args->pad_length = pad_length;
  s5args->direction = direction;
  s5args->rows = rows_per_task2;
  for (j=MyFirst; j<MyLast; j+=rows_per_task2) {
    tpc_call( 1, 3,
	&x[2*j*(n1+pad_length)], bytes_per_row*rows_per_task2, TPC_INOUT_ARG,
	upriv_vec, bytes_per_row, TPC_IN_ARG,
	s5args, sizeof(struct FFTsteps23args), TPC_IN_ARG );
  }
  tpc_wait_all();


  {;};	// BARRIER ============================================================

  if ((MyNum == 0) || (dostats)) {
    {(clocktime1) = fft_get_time();};
  }

  /* transpose back */
  //Transpose(n1, x, scratch, MyNum, MyFirst, MyLast, pad_length);
  tpc_traspose(x, n1, trasn_block);

  if ((MyNum == 0) || (dostats)) {
    {(clocktime2) = fft_get_time();};
    *l_transtime += (clocktime2-clocktime1);
  }

  {;};	// BARRIER ============================================================

  /* copy columns from scratch to x */
  /*if ((test_result) || (doprint)) {  
    for (j=MyFirst; j<MyLast; j++) {
      CopyColumn(n1, &scratch[2*j*(n1+pad_length)], &x[2*j*(n1+pad_length)]); 
    }  
  }*/

  {;};	// BARRIER ============================================================
}
