#ifndef __SCOOP_API_H__
#define __SCOOP_API_H__

#include <stdint.h>
#include <stdio.h>

// Bit-masks for supported argument flags and helping macros
#define SCOOP_IN_ARG                      0x1
#define SCOOP_OUT_ARG                     0x2
#define SCOOP_INOUT_ARG                   0x3
#define SCOOP_STRIDE_ARG                  0x4
#define SCOOP_SAFE_ARG                    0x8
#define SCOOP_BYVALUE_ARG                 0x9
#define SCOOP_REGION_ARG                  0x16
#define SCOOP_REDUCTION_ARG               0x35
#define SCOOP_HIGHPRIORITY_ARG            0x64

#define SCOOP_IS_INARG(x)                 ((x) & SCOOP_IN_ARG)
#define SCOOP_IS_OUTARG(x)                ((x) & SCOOP_OUT_ARG)
#define SCOOP_IS_INOUTARG(x)              ((x) & SCOOP_INOUT_ARG)
#define SCOOP_IS_HIGHPRIORITYARG(x)       ((x) & SCOOP_HIGHPRIORITY_ARG)
#define SCOOP_IS_REDUCTIONARG(x)          ((x) & SCOOP_REDUCTION_ARG)
#define SCOOP_IS_STRIDEARG(x)             ((x) & SCOOP_STRIDE_ARG)
#define SCOOP_IS_SAFEARG(x)               ((x) & SCOOP_SAFE_ARG)
#define SCOOP_IS_BYVALUEARG(x)            ((x) & SCOOP_BYVALUE_ARG)
#define SCOOP_IS_REGIONARG(x)             ((x) & SCOOP_REGION_ARG)

// NOTE: no write on globals

// NOTE: Allocate args and types in the stack
void _sys_spawn(unsigned int id, void** args, unsigned int* types, unsigned int num_args);
// NOTE: Allocate ptrs in the stack
void _sys_wait_on(void** ptrs, unsigned int num_ptrs);

// NOTE: create
// void (*_sys_task_table[]) () = { dpotrf_tile, dgemm_tile, dtrsm_tile, dsyrk_tile};

// sed css/myrmics

#endif
