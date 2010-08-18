/*
 *  discretize.c
 *  
 *  Transport module.
 *  Main kernel.
 *
 *  Created by John Linford on 4/8/08.
 *  Copyright 2008 Transatlantic Giraffe. All rights reserved.
 *
 */
#include <simdmath.h>
#include <spu_intrinsics.h>

#include "params.h"
#include "sequoia.h"
//#include <stdio.h>
#include <stdint.h>

#ifndef SEQUOIA_SPE_THREAD_NUM_FN
#define SEQUOIA_SPE_THREAD_NUM_FN 6
#endif
#include "cell_spe_macros.h"
extern spe_profiler_results_package_t spe_profiler;



/* 
 * The core upwinded advection/diffusion equation.
 * c = conc, w = wind, d = diff
 * x2l is the 2-left neighbor of x, etc.
 * x2r is the 2-right neighbor of x, etc.
 */

vector real_t
advec_diff_v(vector real_t cell_size,
             vector real_t c2l, vector real_t w2l, vector real_t d2l, 
             vector real_t c1l, vector real_t w1l, vector real_t d1l, 
             vector real_t   c, vector real_t   w, vector real_t   d, 
             vector real_t c1r, vector real_t w1r, vector real_t d1r, 
             vector real_t c2r, vector real_t w2r, vector real_t d2r)
{    
    vector real_t acc1, acc2, acc3;
    vector real_t wind, diff_term, advec_term;
    vector real_t advec_term_pos, advec_term_neg;
    vector real_t advec_termR, advec_termL;
    
    const vector real_t FIVE  = SPLAT_CONST(5.0);
    const vector real_t TWO   = SPLAT_CONST(2.0);
    const vector real_t ZERO  = SPLAT_CONST(0.0);
    const vector real_t HALF  = SPLAT_CONST(0.5);
    const vector real_t SIXTH = SPLAT_CONST(1.0/6.0);

    acc1 = spu_add(w1l, w);
    wind = spu_mul(acc1, HALF);
    acc1 = spu_mul(c1l, FIVE);
    acc2 = spu_mul(c, TWO);
    advec_term_pos = spu_add(acc1, acc2);
    advec_term_pos = spu_sub(advec_term_pos, c2l);
    acc1 = spu_mul(c1l, TWO);
    acc2 = spu_mul(c, FIVE);
    advec_term_neg = spu_add(acc1, acc2);
    advec_term_neg = spu_sub(advec_term_neg, c1r);
    acc1 = (vector real_t)spu_cmpgt(wind, ZERO);
    acc1 = spu_and(acc1, advec_term_pos);
    acc2 = (vector real_t)spu_cmpgt(ZERO, wind);
    acc2 = spu_and(acc2, advec_term_neg);
    advec_termL = spu_add(acc1, acc2);
    advec_termL = spu_mul(advec_termL, SIXTH);
    advec_termL = spu_mul(advec_termL, wind);
    acc1 = spu_add(w1r, w);
    wind = spu_mul(acc1, HALF);
    acc1 = spu_mul(c, FIVE);
    acc2 = spu_mul(c1r, TWO);
    advec_term_pos = spu_add(acc1, acc2);
    advec_term_pos = spu_sub(advec_term_pos, c1l);
    acc1 = spu_mul(c, TWO);
    acc2 = spu_mul(c1r, FIVE);
    advec_term_neg = spu_add(acc1, acc2);
    advec_term_neg = spu_sub(advec_term_neg, c2r);
    acc1 = (vector real_t)spu_cmpgt(wind, ZERO);
    acc1 = spu_and(acc1, advec_term_pos);
    acc2 = (vector real_t)spu_cmpgt(ZERO, wind);
    acc2 = spu_and(acc2, advec_term_neg);
    advec_termR = spu_add(acc1, acc2);
    advec_termR = spu_mul(advec_termR, SIXTH);
    advec_termR = spu_mul(advec_termR, wind);
    acc1 = spu_sub(advec_termL, advec_termR);
    advec_term = VEC_DIVIDE(acc1, cell_size);
    acc1 = spu_add(d1l, d);
    acc1 = spu_mul(acc1, HALF);
    acc3 = spu_sub(c1l, c);
    acc1 = spu_mul(acc1, acc3);
    acc2 = spu_add(d, d1r);
    acc2 = spu_mul(acc2, HALF);
    acc3 = spu_sub(c, c1r);
    acc2 = spu_mul(acc2, acc3);
    acc1 = spu_sub(acc1, acc2);
    acc2 = spu_mul(cell_size, cell_size);
    diff_term = VEC_DIVIDE(acc1, acc2);
    return spu_add(advec_term, diff_term);
}

/*
 * Applies the advection / diffusion equation to vector data
 */
void space_advec_diff_v(const uint32_t n, 
                        volatile vector real_t *c, 
                        volatile vector real_t *w, 
                        volatile vector real_t *d, 
                        vector real_t *cb, 
                        vector real_t *wb, 
                        vector real_t *db, 
                        vector real_t cell_size, 
                        volatile vector real_t *dcdx)
{    
    uint32_t i, x;
    
    /* Do boundary cell c[0] explicitly */
    dcdx[0] = advec_diff_v(cell_size,
                         cb[0], wb[0], db[0],  /* 2-left neighbors */
                         cb[1], wb[1], db[1],  /* 1-left neighbors */
                         c[0], w[0], d[0],     /* Values */
                         c[1], w[1], d[1],     /* 1-right neighbors */
                         c[2], w[2], d[2]);    /* 2-right neighbors */
    
    /* Do boundary cell c[1] explicitly */    
    dcdx[1] = advec_diff_v(cell_size,
                         cb[1], wb[1], db[1],  /* 2-left neighbors */
                         cb[2], wb[2], db[2],  /* 1-left neighbors */
                         c[1], w[1], d[1],     /* Values */
                         c[2], w[2], d[2],     /* 1-right neighbors */
                         c[3], w[3], d[3]);    /* 2-right neighbors */
    

    i = 2;
    x = n-2;
/*
    while(x > 4)
    {
        dcdx[i] = advec_diff_v(cell_size,
                               c[i-2], w[i-2], d[i-2], 
                               c[i-1], w[i-1], d[i-1],
                               c[i],   w[i],   d[i],  
                               c[i+1], w[i+1], d[i+1],
                               c[i+2], w[i+2], d[i+2]);
        ++i;
        dcdx[i] = advec_diff_v(cell_size,
                               c[i-2], w[i-2], d[i-2],
                               c[i-1], w[i-1], d[i-1],
                               c[i],   w[i],   d[i], 
                               c[i+1], w[i+1], d[i+1],
                               c[i+2], w[i+2], d[i+2]);
        ++i;
        dcdx[i] = advec_diff_v(cell_size,
                               c[i-2], w[i-2], d[i-2],
                               c[i-1], w[i-1], d[i-1],
                               c[i],   w[i],   d[i],  
                               c[i+1], w[i+1], d[i+1],
                               c[i+2], w[i+2], d[i+2]);
        ++i;
        dcdx[i] = advec_diff_v(cell_size,
                               c[i-2], w[i-2], d[i-2],  
                               c[i-1], w[i-1], d[i-1], 
                               c[i],   w[i],   d[i],  
                               c[i+1], w[i+1], d[i+1],
                               c[i+2], w[i+2], d[i+2]);
        ++i;
        x -= 4;
    }
*/
    while(x > 0)
    {
        dcdx[i] = advec_diff_v(cell_size,
                               c[i-2], w[i-2], d[i-2],  /* 2-left neighbors */
                               c[i-1], w[i-1], d[i-1],  /* 1-left neighbors */
                               c[i],   w[i],   d[i],    /* Values */
                               c[i+1], w[i+1], d[i+1],  /* 1-right neighbors */
                               c[i+2], w[i+2], d[i+2]); /* 2-right neighbors */        
        ++i;
        --x;
    }
    
    /* Do boundary cell c[n-2] explicitly */
    dcdx[n-2] = advec_diff_v(cell_size,
                           c[n-4], w[n-4], d[n-4],  /* 2-left neighbors */
                           c[n-3], w[n-3], d[n-3],  /* 1-left neighbors */
                           c[n-2], w[n-2], d[n-2],  /* Values */
                           cb[1],  wb[1],  db[1],   /* 1-right neighbors */
                           cb[2],  wb[2],  db[2]);  /* 2-right neighbors */
    
    /* Do boundary cell c[n-1] explicitly */
    dcdx[n-1] = advec_diff_v(cell_size,
                           c[n-3], w[n-3], d[n-3],  /* 2-left neighbors */
                           c[n-2], w[n-2], d[n-2],  /* 1-left neighbors */
                           c[n-1], w[n-1], d[n-1],  /* Values */
                           cb[2],  wb[2],  db[2],   /* 1-right neighbors */
                           cb[3],  wb[3],  db[3]);  /* 2-right neighbors */
}

void discretize(const uint32_t n, 
                vector real_t *conc_in, 
                vector real_t *wind, 
                vector real_t *diff, 
                vector real_t *concbound, 
                vector real_t *windbound, 
                vector real_t *diffbound, 
                vector real_t cell_size, 
                vector real_t dt, 
                vector real_t *conc_out)
{
    uint32_t i, x;
    vector real_t acc;
    vector real_t c[n];
    vector real_t dcdx[n];
    
    const vector real_t HALF  = SPLAT_CONST(0.5);

    /* Copy original values  */
/*
    i=0; x=n;
    while(x > 8)
    {
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        x -= 8;
    }
    while(x > 4)
    {
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        c[i] = conc_out[i] = conc_in[i]; ++i;
        x -= 4;
    }
    while(x > 0)
    {
        c[i] = conc_out[i] = conc_in[i]; ++i;
        --x;
    }
    
*/
    space_advec_diff_v(n, conc_in, wind, diff, concbound, windbound, diffbound, cell_size, dcdx);
    
    i=0; x=n;
/*
    while(x > 8)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        x -= 8;
    }
    while(x > 4)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        x -= 4;
    }
*/
    while(x > 0)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        --x;
    }
    
    space_advec_diff_v(n, c, wind, diff, concbound, windbound, diffbound, cell_size, dcdx);
    
    i=0; x=n;
/*
    while(x > 8)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        x -= 8;
    }
    while(x > 4)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        x -= 4;
    }
*/
    while(x > 0)
    {
        c[i] = spu_madd(dt, dcdx[i], c[i]); ++i;
        --x;
    }

    #define UNROLL_ELEMENT \
    acc = spu_add(conc_out[i], c[i]); \
    conc_out[i] = spu_mul(HALF, acc); \
    acc = spu_splats((real_t)0.0); \
    acc = (vector real_t)spu_cmpgt(conc_out[i], acc); \
    conc_out[i] = spu_and(conc_out[i], acc)
    
    i=0; x=n;
/*
    while(x > 8)
    {
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        x -= 8;
    }
    while(x > 4)
    {
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        UNROLL_ELEMENT; ++i;
        x -= 4;
    }
*/
    while(x > 0)
    {
        UNROLL_ELEMENT; ++i;
        --x;
    }
    
    #undef UNROLL_ELEMENT
}


/*
 *  discretize_leaf.c
 *  fixedgrid sequoia
 *
 *  Jae-Seung Yeom <jyeom@cs.vt.edu>
 *
 *  Computer Science Dept. VirginiaTech
 *
 */

#define _RESTRICT_  __restrict

//#define DOUBLE_PRECISION 1
//#if DOUBLE_PRECISION == 1
void merge_as_vector(real_t* _RESTRICT_ s, vector real_t* _RESTRICT_ vo, uint32_t n)
{
    const vector unsigned char PATTERN1 = {0x00, 0x01, 0x02, 0x03, 0x04, \
                                           0x05, 0x06, 0x07, 0x10, 0x11,\
                                           0x12, 0x13, 0x14, 0x15, 0x16, 0x17};
    const vector unsigned char PATTERN2 = {0x08, 0x09, 0x0a, 0x0b, 0x0c, \
                                           0x0d, 0x0e, 0x0f, 0x18, 0x19, \
                                           0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};

    n = (n +0x1) & (~0x1);

    vector real_t* _RESTRICT_ v1 = (vector real_t*) s;
    vector real_t* _RESTRICT_ v2 = (vector real_t*) (s+n);
   /* 
    while(n >= 16)
    {
        vector real_t tmp0 = spu_shuffle(v1[0], v2[0], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v1[0], v2[0], PATTERN2);
        vector real_t tmp2 = spu_shuffle(v1[1], v2[1], PATTERN1);
        vector real_t tmp3 = spu_shuffle(v1[1], v2[1], PATTERN2);
        vector real_t tmp4 = spu_shuffle(v1[2], v2[2], PATTERN1);
        vector real_t tmp5 = spu_shuffle(v1[2], v2[2], PATTERN2);
        vector real_t tmp6 = spu_shuffle(v1[3], v2[3], PATTERN1);
        vector real_t tmp7 = spu_shuffle(v1[3], v2[3], PATTERN2);
        vector real_t tmp8 = spu_shuffle(v1[4], v2[4], PATTERN1);
        vector real_t tmp9 = spu_shuffle(v1[4], v2[4], PATTERN2);
        vector real_t tmp10 = spu_shuffle(v1[5], v2[5], PATTERN1);
        vector real_t tmp11 = spu_shuffle(v1[5], v2[5], PATTERN2);
        vector real_t tmp12 = spu_shuffle(v1[6], v2[6], PATTERN1);
        vector real_t tmp13 = spu_shuffle(v1[6], v2[6], PATTERN2);
        vector real_t tmp14 = spu_shuffle(v1[7], v2[7], PATTERN1);
        vector real_t tmp15 = spu_shuffle(v1[7], v2[7], PATTERN2);

        v1 += 8;
        v2 += 8;

        vo[0] = tmp0;
        vo[1] = tmp1;
        vo[2] = tmp2;
        vo[3] = tmp3;
        vo[4] = tmp4;
        vo[5] = tmp5;
        vo[6] = tmp6;
        vo[7] = tmp7;
        vo[8] = tmp8;
        vo[9] = tmp9;
        vo[10] = tmp10;
        vo[11] = tmp11;
        vo[12] = tmp12;
        vo[13] = tmp13;
        vo[14] = tmp14;
        vo[15] = tmp15;

        vo += 16;
        n -= 16;
    }

    while(n >= 4)
    {
        vector real_t tmp0 = spu_shuffle(v1[0], v2[0], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v1[0], v2[0], PATTERN2);
        vector real_t tmp2 = spu_shuffle(v1[1], v2[1], PATTERN1);
        vector real_t tmp3 = spu_shuffle(v1[1], v2[1], PATTERN2);

        v1 += 2;
        v2 += 2;

        vo[0] = tmp0;
        vo[1] = tmp1;
        vo[2] = tmp2;
        vo[3] = tmp3;

        vo += 4;
        n -= 4;
    }
*/
    while(n > 0)
    {
        vector real_t tmp0 = spu_shuffle(v1[0], v2[0], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v1[0], v2[0], PATTERN2);

        v1 += 1;
        v2 += 1;

        vo[0] = tmp0;
        vo[1] = tmp1;

        vo += 2;
        n -= 2;
    }
    
}

void split_as_scalar(vector real_t* _RESTRICT_ v, real_t* _RESTRICT_ s, uint32_t n)
{
    const vector unsigned char PATTERN1 = {0x00, 0x01, 0x02, 0x03, 0x04, \
                                           0x05, 0x06, 0x07, 0x10, 0x11,\
                                           0x12, 0x13, 0x14, 0x15, 0x16, 0x17};
    const vector unsigned char PATTERN2 = {0x08, 0x09, 0x0a, 0x0b, 0x0c, \
                                           0x0d, 0x0e, 0x0f, 0x18, 0x19, \
                                           0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};

    n = (n +0x1) & (~0x1);

    vector real_t* _RESTRICT_ so1 = (vector real_t*) s;
    vector real_t* _RESTRICT_ so2 = (vector real_t*) (s+n);
   /* 
    while(n >= 16)
    {
        vector real_t tmp0 = spu_shuffle(v[0], v[1], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v[0], v[1], PATTERN2);
        vector real_t tmp2 = spu_shuffle(v[2], v[3], PATTERN1);
        vector real_t tmp3 = spu_shuffle(v[2], v[3], PATTERN2);
        vector real_t tmp4 = spu_shuffle(v[4], v[5], PATTERN1);
        vector real_t tmp5 = spu_shuffle(v[4], v[5], PATTERN2);
        vector real_t tmp6 = spu_shuffle(v[6], v[7], PATTERN1);
        vector real_t tmp7 = spu_shuffle(v[6], v[7], PATTERN2);
        vector real_t tmp8 = spu_shuffle(v[8], v[9], PATTERN1);
        vector real_t tmp9 = spu_shuffle(v[8], v[9], PATTERN2);
        vector real_t tmp10 = spu_shuffle(v[10], v[11], PATTERN1);
        vector real_t tmp11 = spu_shuffle(v[10], v[11], PATTERN2);
        vector real_t tmp12 = spu_shuffle(v[12], v[13], PATTERN1);
        vector real_t tmp13 = spu_shuffle(v[12], v[13], PATTERN2);
        vector real_t tmp14 = spu_shuffle(v[14], v[15], PATTERN1);
        vector real_t tmp15 = spu_shuffle(v[14], v[15], PATTERN2);

        v += 16;

        so1[0] = tmp0;
        so1[1] = tmp2;
        so1[2] = tmp4;
        so1[3] = tmp6;
        so1[4] = tmp8;
        so1[5] = tmp10;
        so1[6] = tmp12;
        so1[7] = tmp14;
        so2[0] = tmp1;
        so2[1] = tmp3;
        so2[2] = tmp5;
        so2[3] = tmp7;
        so2[4] = tmp9;
        so2[5] = tmp11;
        so2[6] = tmp13;
        so2[7] = tmp15;

        so1 += 8;
        so2 += 8;
        n -= 16;
    }

    while(n >= 4)
    {
        vector real_t tmp0 = spu_shuffle(v[0], v[1], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v[0], v[1], PATTERN2);
        vector real_t tmp2 = spu_shuffle(v[2], v[3], PATTERN1);
        vector real_t tmp3 = spu_shuffle(v[2], v[3], PATTERN2);

        v += 4;

        so1[0] = tmp0;
        so1[1] = tmp2;
        so2[0] = tmp1;
        so2[1] = tmp3;

        so1 += 2;
        so2 += 2;

        n -= 4;
    }
*/
    while(n > 0)
    {
        vector real_t tmp0 = spu_shuffle(v[0], v[1], PATTERN1);
        vector real_t tmp1 = spu_shuffle(v[0], v[1], PATTERN2);

        v += 2;

        so1[0] = tmp0;
        so2[0] = tmp1;

        so1 += 1;
        so2 += 1;

        n -= 2;
    }
    
}
//#endif  // DOUBLE_PRECISION

void create_shift_boundary(vector real_t *cbound, vector real_t *wbound, vector real_t *dbound, \
                           vector real_t *c, vector real_t *w, vector real_t *d, uint32_t length)
{ 
    cbound[0] = c[length-2]; 
    cbound[1] = c[length-1]; 
    cbound[2] = c[0];        
    cbound[3] = c[1];        
    wbound[0] = w[length-2]; 
    wbound[1] = w[length-1]; 
    wbound[2] = w[0];        
    wbound[3] = w[1];        
    dbound[0] = d[length-2]; 
    dbound[1] = d[length-1]; 
    dbound[2] = d[0];        
    dbound[3] = d[1];        
}


#define IS_ROW 0
#define IS_COL 1

void discretize_leaf(sqArray_t *sq_dims, sqArray_t *sq_DXYT, sqArray_t *sq_wind, sqArray_t *sq_diff, sqArray_t *sq_concIn, sqArray_t *sq_concOut, int row_or_col)
{
    unsigned long long LScopy_start;
    uint32_t SZ = ((uint32_t*)((unsigned char*)sq_dims->ptr))[2];

    vector real_t tmpv[SZ];
    vector real_t* _RESTRICT_ vconc;
    vector real_t* _RESTRICT_ vbuff;
    vector real_t* _RESTRICT_ vwind;
    vector real_t* _RESTRICT_ vdiff;

    vector real_t cbound[4];
    vector real_t wbound[4];
    vector real_t dbound[4];

    real_t *DXYT =    (real_t*)((unsigned char*)sq_DXYT->ptr);
    real_t *concIn =  (real_t*)((unsigned char*)sq_concIn->ptr);
    real_t *wind =    (real_t*)((unsigned char*)sq_wind->ptr);
    real_t *diff =    (real_t*)((unsigned char*)sq_diff->ptr);
    real_t *concOut = (real_t*)((unsigned char*)sq_concOut->ptr);

    vector real_t vsize = spu_splats(DXYT[0]);
    vector real_t vdt = spu_splats(DXYT[1]);

    SEQUOIA_SPE_PROFILER_SPE_LSCOPY_START();
    if (row_or_col == IS_ROW) {
        merge_as_vector(wind,   tmpv, SZ);
        memcpy(wind, tmpv, SZ*VECTOR_LENGTH*sizeof(real_t));
        merge_as_vector(diff,   tmpv, SZ);
        memcpy(diff, tmpv, SZ*VECTOR_LENGTH*sizeof(real_t));
        merge_as_vector(concIn, tmpv, SZ);
        memcpy(concIn, tmpv, SZ*VECTOR_LENGTH*sizeof(real_t));
    } else {
        memcpy(concIn, tmpv, SZ*VECTOR_LENGTH*sizeof(real_t));
    }
    SEQUOIA_SPE_PROFILER_SPE_LSCOPY_END(row_or_col);

    vconc = (vector real_t*) concIn;
    vwind = (vector real_t*) wind;
    vdiff = (vector real_t*) diff;
    vbuff = (vector real_t*) tmpv;


    create_shift_boundary(cbound, wbound, dbound, vconc, vwind, vdiff, SZ);

    discretize(SZ, vconc, vwind, vdiff, cbound, wbound, dbound, vsize, vdt, vbuff);

    SEQUOIA_SPE_PROFILER_SPE_LSCOPY_START();
    if (row_or_col == IS_ROW) {
        split_as_scalar(vbuff, concOut, SZ);
    }
    SEQUOIA_SPE_PROFILER_SPE_LSCOPY_END(row_or_col);
}

void discretize_all_rows_leaf(sqArray_t *sq_dims, sqArray_t *sq_DXYT, sqArray_t *sq_wind, sqArray_t *sq_diff, sqArray_t *sq_concIn, sqArray_t *sq_concOut)
{
    discretize_leaf(sq_dims, sq_DXYT, sq_wind, sq_diff, sq_concIn, sq_concOut, IS_ROW);
}

void discretize_all_cols_leaf(sqArray_t *sq_dims, sqArray_t *sq_DXYT, sqArray_t *sq_wind, sqArray_t *sq_diff, sqArray_t *sq_concIn, sqArray_t *sq_concOut)
{
    discretize_leaf(sq_dims, sq_DXYT, sq_wind, sq_diff, sq_concIn, sq_concOut, IS_COL);
}