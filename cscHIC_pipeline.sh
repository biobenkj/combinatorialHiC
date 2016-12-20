#Author: Vijay Ramani
#Please read manuscript before running this!! All aspects of analysis are covered in methods section.
#Questions / omissions? vramani@uw.edu
#Load necessary dependencies from modules
module load bowtie2/2.2.3
module load python/2.7.3
module load bedtools/latest
module load samtools/latest
#VARS
bc1=$1 #Inner barcode file
fq_r1=$2 #R1 Fastq
fq_r2=$3 #R2 Fastq
barcodes=$4 #Outer barcode file
bc_assoc=$5 #Outfile prefix
outdir=$6 #outdir
#MAIN
mkdir $outdir #Make outdir
rm $outdir/*.html #And clear out all the results files
#Demultiplex reads by inline barcodes
SeqPrep -A AGATCGGAAGAGCGATCGG -B AGATCGGAAGAGCGTCGTG -f $fq_r1  -r $fq_r2 -1 $fq_r1.clipped -2 $fq_r2.clipped > seq_prep.txt 2>> adaptor_clipping_stats
python ~/python/git/vramani/inline_splitter.py $fq_r1.clipped $fq_r2.clipped $barcodes $fq_r1.split $fq_r2.split 2> $outdir/splitting_stats.html
#Run analyze_scDHC_V2design.py, which searches for the adaptor and clips it out
python ~/python/scDHCpipeline/git/analyze_scDHC_V2design.py $bc1 $fq_r1.split $fq_r2.split $fq_r1.bc_clipped $fq_r2.bc_clipped > $outdir/$bc_assoc
#Align reads to combo-reference using bowtie2
bowtie2 -x ~/bowtie/human_mouse_combo/combo_hg19_mm10 -p 4 -U $fq_r1.bc_clipped -S $outdir/$fq_r1.sam 2> $outdir/$fq_r1.mapping_stats&
bowtie2 -x ~/bowtie/human_mouse_combo/combo_hg19_mm10 -p 4 -U $fq_r2.bc_clipped -S $outdir/$fq_r2.sam 2> $outdir/$fq_r2.mapping_stats&
wait
#Compute total # of bc_clipped reads and store that value
wc -l $fq_r1.bc_clipped > $bc_assoc.ph1
read reads_r1 junk < $bc_assoc.ph1
total_reads=`expr $reads_r1 / 4`
#Housekeeping
rm $bc_assoc.ph1
#Convert sam files to bam
samtools view -bS $outdir/$fq_r1.sam | bedtools bamtobed -i stdin > $outdir/$fq_r1.bed&
samtools view -bS $outdir/$fq_r2.sam | bedtools bamtobed -i stdin > $outdir/$fq_r2.bed&
wait
cd $outdir
#Sort out all multimapping reads (MAPQ > 30)
awk '$5 > 30' $fq_r1.bed > $fq_r1.bed.mapq0&
awk '$5 > 30' $fq_r2.bed > $fq_r2.bed.mapq0&
wait
#Sort bed files lexicographically to enable bedtools closest
sort -k1,1 -k2,2n $fq_r1.bed.mapq0 > $fq_r1.bed.mapq0.sorted&
sort -k1,1 -k2,2n $fq_r2.bed.mapq0 > $fq_r2.bed.mapq0.sorted&
wait
#Use bedtools closest to find the closest DpnII sites for each read. In most cases this should be immediately proximal to one of the read ends
bedtools closest -t first -d -a $fq_r1.bed.mapq0.sorted -b /net/shendure/vol8/projects/HiC.TCC.DHC.project/nobackup/HiC_resources/combo_hg19_mm10.dpnii.bed.fixed.sorted > $fq_r1.bed.mapq0.dre&
bedtools closest -t first -d -a $fq_r2.bed.mapq0.sorted -b /net/shendure/vol8/projects/HiC.TCC.DHC.project/nobackup/HiC_resources/combo_hg19_mm10.dpnii.bed.fixed.sorted > $fq_r2.bed.mapq0.dre&
wait
#Concatenate bed files and sort by read ID so that pairs immediately follow each other in the file
cat $fq_r1.bed.mapq0.dre $fq_r2.bed.mapq0.dre > $bc_assoc.concat.bed
sort -s -k 4 $bc_assoc.concat.bed > $bc_assoc.concat.sorted.bed
#Merge to bedpe and associate reads
python ~/python/scDHCpipeline/git/catbed2bedpe.py $bc_assoc.concat.sorted.bed $bc_assoc $bc_assoc.unmatched.bedpe $bc_assoc.matching.html > $bc_assoc.bedpe.mapq0
#sort lexicographically to enable O(n) deduplication with limited memory overhead
sort -k12,13 -k1,1 -k2,2n -k3,3 -k4,4n $bc_assoc.bedpe.mapq0 > $bc_assoc.bedpe.mapq0.sorted
#Deduplicate reads based on unique starts, ends, and barcodes with 5 bp of wiggle room
python ~/python/scDHCpipeline/git/dedupe_scDHC.py $bc_assoc.bedpe.mapq0.sorted > $bc_assoc.bedpe.mapq0.deduped
#Check some QC stats
#Reads where both mates map uniquely (MAPQ > 10)?
wc -l $bc_assoc.bedpe.mapq0 > $bc_assoc.ph1
read mapped_reads_mapq < $bc_assoc.ph1
#Reads where both deduplicated mates map uniquely (MAPQ > 10)?
wc -l $bc_assoc.bedpe.mapq0.deduped > $bc_assoc.ph1
read associated_reads_mapq_dedupe junk < $bc_assoc.ph1
#Cleanup
rm $bc_assoc.ph1
#Remove satellite sequences / unplaced contigs from deduped bedpe file
python ~/python/scDHCpipeline/git/filter_bedpe.py /net/shendure/vol8/projects/HiC.TCC.DHC.project/nobackup/HiC_resources/combo_hg19_mm10.genomesize $bc_assoc.bedpe.mapq0.deduped > $bc_assoc.bedpe.mapq0.deduped.filtered
#Spit out some basic statistics to HTML
cat splitting_stats.html >> $bc_assoc.baseline_stats.html
echo "<H3>Total Reads With Barcode Found:$total_reads</H3>" >> $bc_assoc.baseline_stats.html
cat $bc_assoc.matching.html >> $bc_assoc.baseline_stats.html
echo "<H3>Total Mapped Reads MAPQ > 30:$mapped_reads_mapq</H3>" >> $bc_assoc.baseline_stats.html
echo "<H3>Total Deduped Mapped Reads MAPQ > 30:$associated_reads_mapq_dedupe</H3>" >> $bc_assoc.baseline_stats.html
#Compute summary statistics for both raw and deduplicated libraries and write to html
python ~/python/scDHCpipeline/git/sort_strandedness.py $bc_assoc.bedpe.mapq0 > $bc_assoc.deduped.stats.html&
python ~/python/scDHCpipeline/git/sort_strandedness.py $bc_assoc.bedpe.mapq0.deduped.filtered > $bc_assoc.associated.stats.html&
wait
#Compute breakdown of species specificity of barcodes
python ~/python/scDHCpipeline/git/calculate_cell_distro_long.py $bc_assoc.bedpe.mapq0 > $bc_assoc.percentages 2> $bc_assoc.REoccurrences &
python ~/python/scDHCpipeline/git/calculate_cell_distro_long.py $bc_assoc.bedpe.mapq0.deduped.filtered > $bc_assoc.deduped.percentages 2> $bc_assoc.deduped.REoccurrences&
wait
#Write final HTML with stats
cat $bc_assoc.baseline_stats.html $bc_assoc.deduped.stats.html $bc_assoc.associated.stats.html > $bc_assoc.html
#Sort out all cells with >=3000 unique reads and generate matrices with
#resolutions determined in bin_scHiC.py. These matrices are in sparse format.
#python ~/python/scDHCpipeline/git/bin_schic.py /net/shendure/vol8/projects/HiC.TCC.DHC.project/nobackup/HiC_resources/combo_hg19_mm10.genomesizes $bc_assoc.deduped.percentages $bc_assoc.bedpe.mapq0.deduped