/*
 * arch/arm/mm/proc-v7-2level.S
 *
 * Copyright (C) 2001 Deep Blue Solutions Ltd.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#define TTB_S		(1 << 1)
#define TTB_RGN_NC	(0 << 3)
#define TTB_RGN_OC_WBWA	(1 << 3)
#define TTB_RGN_OC_WT	(2 << 3)
#define TTB_RGN_OC_WB	(3 << 3)
#define TTB_NOS		(1 << 5)
#define TTB_IRGN_NC	((0 << 0) | (0 << 6))
#define TTB_IRGN_WBWA	((0 << 0) | (1 << 6))
#define TTB_IRGN_WT	((1 << 0) | (0 << 6))
#define TTB_IRGN_WB	((1 << 0) | (1 << 6))

/* PTWs cacheable, inner WB not shareable, outer WB not shareable */
#define TTB_FLAGS_UP	TTB_IRGN_WB|TTB_RGN_OC_WB
#define PMD_FLAGS_UP	PMD_SECT_WB

/* PTWs cacheable, inner WBWA shareable, outer WBWA not shareable */
#define TTB_FLAGS_SMP	TTB_IRGN_WBWA|TTB_S|TTB_NOS|TTB_RGN_OC_WBWA
#define PMD_FLAGS_SMP	PMD_SECT_WBWA|PMD_SECT_S

/*
 *	cpu_v7_switch_mm(pgd_phys, tsk)
 *
 *	Set the translation table base pointer to be pgd_phys
 *
 *	- pgd_phys - physical address of new TTB
 *
 *	It is assumed that:
 *	- we are not using split page tables
 */
ENTRY(cpu_v7_switch_mm)
#ifdef CONFIG_MMU
	mov	r2, #0
	mmid	r1, r1				@ get mm->context.id
	ALT_SMP(orr	r0, r0, #TTB_FLAGS_SMP)
	ALT_UP(orr	r0, r0, #TTB_FLAGS_UP)
#ifdef CONFIG_ARM_ERRATA_430973
	mcr	p15, 0, r2, c7, c5, 6		@ flush BTAC/BTB
#endif
#ifdef CONFIG_PID_IN_CONTEXTIDR
	mrc	p15, 0, r2, c13, c0, 1		@ read current context ID
	lsr	r2, r2, #8			@ extract the PID
	bfi	r1, r2, #8, #24			@ insert into new context ID
#endif
#ifdef CONFIG_ARM_ERRATA_754322
	dsb
#endif
	mcr	p15, 0, r1, c13, c0, 1		@ set context ID
	isb
	mcr	p15, 0, r0, c2, c0, 0		@ set TTB 0
	isb
#endif
	mov	pc, lr
ENDPROC(cpu_v7_switch_mm)

/*
 *	cpu_v7_set_pte_ext(ptep, pte)
 *
 *	Set a level 2 translation table entry.
 *
 *	- ptep  - pointer to level 2 translation table entry
 *		  (hardware version is stored at +2048 bytes)
 *	- pte   - PTE value to store
 *	- ext	- value for extended PTE bits
 */
///TP: Linux Page table format
///-----------------------------------------------
///|31     12|11|10| 9| 8| 7| 6| 5| 4| 3| 2| 1| 0|
///|PA[31:12]| N| S|XN| U| R| D|   MEMF    | Y|PV|
///-----------------------------------------------
/// N: NONE, S: SHARED, XN: XN, U: USER, R:RDONLY, D: DIRTY, 
/// MEMF: mem type or file(if !present), Y: YOUNG, P: PRESENT, V: VALID
///
///TP: HW Page table(2nd) format
///-----------------------------------------------
///|31     12|11|10| 9| 8| 7| 6| 5| 4| 3| 2| 1| 0|
///|PA[31:12]|nG| S|AP|TEX[2:0]| AP10| C| B| 1|XN|
///-----------------------------------------------
/// nG: not Global, S: Shareable, AP: APX/AP[2], AP10: AP[1:0], TEX,C,B: memory type 

ENTRY(cpu_v7_set_pte_ext)
#ifdef CONFIG_MMU
	str	r1, [r0]			@ linux version

	bic	r3, r1, #0x000003f0		///TP: clear AP[2:0], TEX[2:0], TEX[2:1] is managed by OS(linux seems not to use it) when SCTLR.TRE=1
	bic	r3, r3, #PTE_TYPE_MASK		///TP: lsb[1:0]
	orr	r3, r3, r2
	orr	r3, r3, #PTE_EXT_AP0 | 2	///TP: small page table

	tst	r1, #1 << 4
	orrne	r3, r3, #PTE_EXT_TEX(1)		///TP: MEM[1:0]=CB[1:0], MEM[2]=TEX[1], ref to the comment below PRRR,NMRR, remember SCTLR.TRE=1

	eor	r1, r1, #L_PTE_DIRTY
	tst	r1, #L_PTE_RDONLY | L_PTE_DIRTY
	orrne	r3, r3, #PTE_EXT_APX		///TP: if RDONLY or not DIRTY, set read-only access permission, this needs APX=1 when SCTLR.AFE=0

	tst	r1, #L_PTE_USER
	orrne	r3, r3, #PTE_EXT_AP1		///TP: PL0 accessible only for AP[1:0]=2 or 3
#ifdef CONFIG_CPU_USE_DOMAINS
	@ allow kernel read/write access to read-only user pages
	tstne	r3, #PTE_EXT_APX
	bicne	r3, r3, #PTE_EXT_APX | PTE_EXT_AP0	///TP: if USER && APX, AP=3'b010
#endif

	tst	r1, #L_PTE_XN
	orrne	r3, r3, #PTE_EXT_XN	///TP: deal with differently located XN, same meaning in linux pt, HW pt

	tst	r1, #L_PTE_YOUNG
	tstne	r1, #L_PTE_VALID
#ifndef CONFIG_CPU_USE_DOMAINS
	eorne	r1, r1, #L_PTE_NONE
	tstne	r1, #L_PTE_NONE
#endif
	moveq	r3, #0		///TP: if !YOUNG or (YOUNG && !VALID)  or if !YOUNG or (YOUNG && !VALID) or (YOUNG && VALID && NONE), it is falut page

 ARM(	str	r3, [r0, #2048]! )
 THUMB(	add	r0, r0, #2048 )
 THUMB(	str	r3, [r0] )
	ALT_SMP(W(nop))
	ALT_UP (mcr	p15, 0, r0, c7, c10, 1)		@ flush_pte
#endif
	mov	pc, lr
ENDPROC(cpu_v7_set_pte_ext)

	/*
	 * Memory region attributes with SCTLR.TRE=1
	 *
	 *   n = TEX[0],C,B
	 *   TR = PRRR[2n+1:2n]		- memory type
	 *   IR = NMRR[2n+1:2n]		- inner cacheable property
	 *   OR = NMRR[2n+17:2n+16]	- outer cacheable property
	 *
	 *			n	TR	IR	OR
	 *   UNCACHED		000	00                  ///TP: strongly ordered(TR)
	 *   BUFFERABLE		001	10	00	00  ///TP: normal(TR), nc(IR)
	 *   WRITETHROUGH	010	10	10	10  ///TP: normal, wtnwa
	 *   WRITEBACK		011	10	11	11  ///TP: normal, wbnwa
	 *   reserved		110
	 *   WRITEALLOC		111	10	01	01  ///TP: normal, wbwa
	 *   DEV_SHARED		100	01                  ///TP: device(TR)
	 *   DEV_NONSHARED	100	01                  ///TP: device
	 *   DEV_WC		001	10
	 *   DEV_CACHED		011	10
	 *
	 * Other attributes:
	 *
	 *   DS0 = PRRR[16] = 0		- device shareable property
	 *   DS1 = PRRR[17] = 1		- device shareable property
	 *   NS0 = PRRR[18] = 0		- normal shareable property
	 *   NS1 = PRRR[19] = 1		- normal shareable property
	 *   NOS = PRRR[24+n] = 1	- not outer shareable
	 */
.equ	PRRR,	0xff0a81a8	///TP: PRRR, NMRR are well defined to match to linux page table memory type
.equ	NMRR,	0x40e040e0

	/*
	 * Macro for setting up the TTBRx and TTBCR registers.
	 * - \ttb0 and \ttb1 updated with the corresponding flags.
	 */
	.macro	v7_ttb_setup, zero, ttbr0, ttbr1, tmp
	mcr	p15, 0, \zero, c2, c0, 2	@ TTB control register
	ALT_SMP(orr	\ttbr0, \ttbr0, #TTB_FLAGS_SMP)
	ALT_UP(orr	\ttbr0, \ttbr0, #TTB_FLAGS_UP)
	ALT_SMP(orr	\ttbr1, \ttbr1, #TTB_FLAGS_SMP)
	ALT_UP(orr	\ttbr1, \ttbr1, #TTB_FLAGS_UP)
	mcr	p15, 0, \ttbr1, c2, c0, 1	@ load TTB1
	.endm

	/*   AT
	 *  TFR   EV X F   I D LR    S
	 * .EEE ..EE PUI. .T.T 4RVI ZWRS BLDP WCAM
	 * rxxx rrxx xxx0 0101 xxxx xxxx x111 xxxx < forced
	 *   01    0 110       0011 1100 .111 1101 < we want
	 */
	.align	2
	.type	v7_crval, #object
v7_crval:
	crval	clear=0x2120c302, mmuset=0x10c03c7d, ucset=0x00c01c7c
