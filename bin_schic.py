#Goal: Given a "percentages" file which specifies the
#species breakdown and coverage within each barcode combination,
#generate sparse matrix files at specified resolutions for each single cell
import os,sys,re
from collections import Counter
from math import sqrt

def normalizeMatrix(matrix):
    '''Given a matrix, root normalize the values in the matrix'''
    cov = Counter() #Store coverage of each bin in a Counter object
    normed = {} #Store the normalized values in a dict
    for i in matrix:
        #Iterate through the matrix and keep track of the counts of each bin
        bin1, bin2, chrom1, chrom2 = i
        count = matrix[i]
        cov[bin1] += count
        cov[bin2] += count
    for i in matrix:
            #Walk through the matrix once again and
            #calculate the normalized values based on
            #the computed coverages
            bin1, bin2, chrom1, chrom2 = i
            normed[i] = float(matrix[i]) / sqrt(cov[bin1]) / sqrt(cov[bin2])
    return normed

def define_bins(chromsizes, resolutions):
    '''Takes chromosome sizes, and a list of desired resolutions and defines the\
        bins that cover the genome at the desired resolution(s)'''
    bins = {} #hash the bins
    valid_chroms = {} #hash the chromosome sizes
    lines = chromsizes.readlines() #Read in the chromosome sizes file as a list
    for resolution in resolutions:
        bins[resolution] = {} #every resolution gets its own dict
    for resolution in resolutions:
        #For each desired resolution
        hindex = 0 #keep the human
        mindex = 0 #and mouse indices separate
        for line in lines:
            #walk through the chrom sizes files
            #and define the bins
            chromname, length = line.split()
            valid_chroms[chromname] = True
            if re.search("human", chromname):
                for i in range(0,int(length),resolution):
                    bins[resolution][(chromname, i)] = hindex
                    hindex += 1
            if re.search("mouse", chromname):
                for i in range(0,int(length),resolution):
                    bins[resolution][(chromname, i)] = mindex
                    mindex += 1
    return bins, valid_chroms

def cell_sort(percentages):
    '''Iterate through the percentages file generated by the scHi-C pipeline, and return a list
        of cell barcodes where the cell has >=1000 unique reads, passes cistrans_cutoff and is 0.95 one species'''
    cells = {}
    for line in percentages:
        #for each barcode combination in the percentages files
        hup, mup, huc, muc, val, tot, bc1, bc2, sig, length, ones, twos, threes, fours, ratio, gtype = line.split()
        if length == "Long": continue #Ignore the "Long"
        if sig == "Randomized": continue #and "randomized" lines
        if float(hup) >= 0.95: #95% one species
            if int(huc) >= 1000: #at least 3000 reads
                if float(ratio) < 1: continue
                identity = ("human", huc)
                barcode = "%s-%s" % (bc1, bc2)
                cells[barcode] = identity #hash the species type and coverage with the cell barcode
        #same applies for mouse cells
        elif float(mup) >= 0.95:
            if float(ratio) < 1: continue
            if int(muc) >= 1000:
                identity = ("mouse", muc)
                barcode = "%s-%s" % (bc1, bc2) 
                cells[barcode] = identity
    return cells

def bedpe_walk(bedpe, cell_list, resolutions, bins, valid_chroms):
    '''bedpe_walk walks through a bedpe file, splits out reads to outfiles of the format bin1<t>bin2<t>count<t>norm_count<t>chrom1<t>chrom2'''
    cell_index = 1
    cell_matrices = {}
    for resolution in resolutions:
        cell_matrices[resolution] = {}
    for line in bedpe:
        n1, f1, r1, n2, f2, r2, name, q1, a2, s1, s2, bc1, bc2, frag1, dist1, frag2, dist2, dupcount = line.split()
        #Checking the species of each mapped mate
        species1 = n1.split("_")[0]
        species2 = n2.split("_")[0]
        #Store the barcode
        barcode = "%s-%s" % (bc1, bc2)
        if barcode in cell_list:
            if species1 != species2: continue #if species don't match throw it out
            if species1 != cell_list[barcode][0]: continue # if it is a contaminating species read, throw it out
            if n1 not in valid_chroms: continue #Ignore the unplaced contigs and decoy sequences
            if n2 not in valid_chroms: continue #Ignore the unplaced contigs and decoy sequences
            for resolution in resolutions:
                if barcode in cell_matrices[resolution]:
                    #Here, we're doing some basic int division to reduce the actual fragment midpoint to
                    #the bin it belongs in, and then using the bin map from define_bins to translate that
                    #into the appropriate bin #
                    pos1_reduce = (int(f1) + int(r1)) / 2 / resolution * resolution #use the fragment midpoint
                    pos2_reduce = (int(f2) + int(r2)) / 2 / resolution * resolution #use the fragment midpoint
                    bin1 = bins[resolution][(n1, pos1_reduce)]
                    bin2 = bins[resolution][(n2, pos2_reduce)]
                    #To save space, only report the bins that are bin1 <= bin2, this effectively halves
                    #space required by the final matrix
                    if bin1 <= bin2:
                        key = (bin1, bin2, n1, n2)
                        cell_matrices[resolution][barcode][key] += 1
                    else:
                        key = (bin2, bin1, n2, n1)
                        cell_matrices[resolution][barcode][key] += 1
                else:
                    #Have to initialize the Counter object if it doesn't already exist
                    cell_matrices[resolution][barcode] = Counter()
                    pos1_reduce = (int(f1) + int(r1)) / 2 / resolution * resolution #use the fragment midpoint
                    pos2_reduce = (int(f2) + int(r2)) / 2 / resolution * resolution #use the fragment midpoint
                    bin1 = bins[resolution][(n1, pos1_reduce)]
                    bin2 = bins[resolution][(n2, pos2_reduce)]
                    if bin1 <= bin2:
                        key = (bin1, bin2, n1, n2)
                        cell_matrices[resolution][barcode][key] += 1
                    else:
                        key = (bin2, bin1, n2, n1)
                        cell_matrices[resolution][barcode][key] += 1
    return cell_matrices

def main():
    genome_file = open(sys.argv[1]) #positional argument 1 --> chromosome sizes
    percentages = open(sys.argv[2]) #positional argument 2 --> percentage file
    bedpe = open(sys.argv[3])       #positional argument 3 --> BEDPE file
    #User defined resolutions (should really be positional argument in the future)
    resolutions = [500000]
    bins, valid_chroms = define_bins(genome_file, resolutions)
    cell_list = cell_sort(percentages)
    cell_matrices = bedpe_walk(bedpe, cell_list, resolutions, bins, valid_chroms)
    #Walk through all desired resolutions and print out the matrices to their own respective
    #out filehandles
    for resolution in resolutions:
        for barcode in cell_matrices[resolution]:
            fho_name = "%s_%s_%s_%s.matrix" % (cell_list[barcode][0], cell_list[barcode][1],  barcode, resolution)
            fho = open(fho_name, 'w')
            norm = normalizeMatrix(cell_matrices[resolution][barcode])
            for i in norm:
                print >> fho, "%s\t%s\t%s\t%s\t%s\t%s" % (i[0],i[1], cell_matrices[resolution][barcode][i], norm[i],i[2], i[3])
            fho.close()
    genome_file.close()
    percentages.close()
    bedpe.close()

if __name__ == "__main__":
    main()