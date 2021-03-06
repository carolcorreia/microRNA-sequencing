##########################################################################
# miRNA-seq analysis of a time course experimental infection in cattle   #
#                                                                        #
#              --- R workflow for the miRDeep2 approach ---              #
#                                 Part 1                                 #
##########################################################################

# Based on the workflow created by Nalpas, Nicolas and Correia, Carol (2015)
# DOI badge: https://doi.org/10.5281/zenodo.16164

# Authors of current version (2.0.0): Correia, C.N. and Nalpas, N.C.
# DOI badge of current version:
# Last updated on 10/01/2018

############################################
# 01 Load and/or install required packages #
############################################

library(here)
library(edgeR)
library(tidyverse)
library(devtools)
library(stringr)
library(magrittr)
library(biobroom)
library(Cairo)
library(extrafont)

# Uncomment functions below to install packages in case you don't have them
# Bioconductor packages
#source("https://bioconductor.org/biocLite.R")
#biocLite("edgeR")


# CRAN packages
#install.packages("here")
#install.packages("tidyverse")
#install.packages("biobroom")
#install.packages("Cairo")
#install.packages("extrafont")

##############################################
# 02 Working directory, fonts, and time zone #
##############################################

# Check working directory
here()

# Define variables for subdirectories
countsDir <- here("quant_mature_counts/")
imgDir <- here("Figures/")
tablesDir <- here("Tables/")

# Define the method used for miRNA identification
method <- "miRDeep2"

# Set time zone
Sys.setenv(TZ = "Europe/London")

# Register fonts with R for the PDF output device
loadfonts()

########################################
# 03 Import miRDeep2 quantifier counts #
########################################

# Create a vector of file names
files <- list.files(path        = countsDir,
                    pattern     = "^6",
                    all.files   = TRUE,
                    full.names  = FALSE,
                    recursive   = FALSE,
                    ignore.case = FALSE)

files
names(files) <- files
length(files)

# Create a dataframe with raw counts for all samples
files %>%
  map_df(~ read_tsv(paste0(countsDir, .x), col_names = TRUE),
         .id = "filename") %>%
  dplyr::rename(gene_name = `#miRNA`, precursor_name = precursor) %>%
  dplyr::select(-c(total, seq, `seq(norm)`)) %>%
  spread(filename, read_count) -> rawCounts

# Check data frame
rawCounts

# Clean column names and add a prefix to avoid sample names starting
# with numbers
colnames(rawCounts) %<>%
  str_replace("_expressed.csv", "") %>%
  str_replace("65", "A65") %>%
  str_replace("66", "A66")

# Check data frame
rawCounts

###############################################################
# 04 Gene annotation using information obtained from GTF file #
###############################################################

# Read in the annotation information
miRNA_info <- read.table(file   = "miRNA_Btaurus.txt",
                         header = TRUE,
                         sep    = "\t",
                         quote  = "")

head(miRNA_info)
dim(miRNA_info)

# Determine which miRNAs have identical mature sequence but
# originate from different precursors and add it to annotation
miRNA_info %<>%
  dplyr::group_by(sequence) %>%
  dplyr::summarise(identical_sequence = paste(gene_id, collapse = ",")) %>%
  dplyr::inner_join(miRNA_info, by = "sequence") %>%
  dplyr::select(starts_with("gene"), chromosome, contains("position"),
                strand, sequence, starts_with("precursor"),
                identical_sequence)

miRNA_info

# Merge gene annotation with the counts and output data
annotCounts <- dplyr::inner_join(x = miRNA_info,
                                 y = rawCounts,
                                 by = c("gene_name", "precursor_name"))

annotCounts %>%
  write_csv(file.path(paste0(tablesDir, method, "_Raw-counts.csv",
                             sep = "")),
            col_names = TRUE)

# Add genes as rownames
annotCounts %<>%
  data.frame() %>%
  column_to_rownames(var = "gene_id")

head(annotCounts)
dim(annotCounts)

##############################################
# 05 Create groups and variables for DGElist #
##############################################

# Select counts only
annotCounts %>%
  dplyr::select(starts_with("A6")) -> counts

head(counts)
dim(counts)

# Define control and treatment groups
colnames(counts) %>%
  as.tibble() %>%
  dplyr::select(sample = value) %>%
  dplyr::mutate(group = sample) -> group

group$group %<>%
  str_replace("A\\d\\d\\d\\d", "") %>%
  str_replace("_pre(1|2)", "Control") %>%
  str_replace("_", "W")

group %<>%
  data.frame() %>%
  column_to_rownames(var = "sample")

head(group)
dim(group)
identical(rownames(group), colnames(counts))

# Select annotation only
annotCounts %>%
  dplyr::select(-starts_with("A6")) -> gene_annot

head(gene_annot)
dim(gene_annot)

#####################
# 06 Create DGElist #
#####################

# Create DGElist
dgelist <- DGEList(counts       = counts,
                   group        = group$group,
                   genes        = gene_annot,
                   lib.size     = NULL,
                   norm.factors = NULL,
                   remove.zeros = FALSE)

names(dgelist)
dim(dgelist)
head(dgelist$counts)
head(dgelist$samples)
head(dgelist$genes)

################################################
# 07 Additional sample information for DGElist #
################################################

# Include Animal ID (cannot start with numbers)
dgelist$samples$animal <- rownames(dgelist$samples)
dgelist$samples$animal %<>%
  str_replace("_.+", "") %>%
  factor()

# Check order of factor levels
levels(dgelist$samples$animal)

# Include time points (avoid using underscores)
dgelist$samples$time.point <- rownames(dgelist$samples)
dgelist$samples$time.point %<>%
  str_replace("A\\d+_", "") %>%
  str_replace("^1", "W1") %>%
  str_replace("^2", "W2") %>%
  str_replace("^6", "W6") %>%
  factor(levels = c("pre2", "pre1", "W1", "W2", "W6", "W10", "W12"))

# Check order of factor levels
levels(dgelist$samples$time.point)

# Convert treatment group to factor
dgelist$samples$group %<>%
  factor(levels = c("Control", "W1", "W2", "W6", "W10", "W12"))

# Check order of factor levels
levels(dgelist$samples$group)

# Check data frame
head(dgelist$samples)

# Output sample information
dgelist$samples %>%
  write_csv(file.path(paste0(tablesDir, method, "_samples-info.csv", sep = "")),
            col_names = TRUE)

################################################
# 08 Density plot: raw gene counts per library #
################################################

# Tidy DGElist and plot data
dgelist %>%
  tidy() %>%
  ggplot() +
    geom_density(aes(x     = log10(count + 1),
                     group = sample), size = 0.1) +
    theme_bw(base_size = 14, base_family = "Calibri") +
    ggtitle(method) +
    ylab("Density of raw gene counts per sample") +
    xlab(expression(paste(log[10], "(counts + 1)"))) -> density_raw


density_raw

# Export image
ggsave(paste0(method, "_Raw-density.pdf", sep = ""),
       plot      = density_raw,
       device    = cairo_pdf,
       limitsize = FALSE,
       dpi       = 300,
       height    = 8,
       width     = 10,
       path      = imgDir)

###########################################
# 09 Remove zero and lowly expressed tags #
###########################################

# Filter non-expressed tags (all genes that have zero counts in all samples)
dgelist_no_zeros <- dgelist[rowSums(dgelist$counts) > 0, ]
dim(dgelist_no_zeros$counts)
head(dgelist_no_zeros$counts)
colnames(dgelist_no_zeros$counts)

# Filter lowly expressed tags, retaining only tags with
# more than 50 counts per million in 10 or more libraries
# (10 libraries correspond to 10 biological replicates and represent
# one time point)
dgelist_filt <- dgelist_no_zeros[rowSums(cpm(dgelist_no_zeros) > 50) >= 10, ]
dim(dgelist_filt$counts)
head(dgelist_filt$counts)

# Ouptut filtered counts
dgelist_filt$counts %>%
  as.data.frame() %>%
  rownames_to_column(var = "miRBaseID") %>%
  write_csv(file.path(paste0(tablesDir, method, "_Filt_counts.csv",
                             sep = "")),
            col_names = TRUE)

##############################
# 10 Recompute library sizes #
##############################

dgelist_filt$samples$lib.size <- colSums(dgelist_filt$counts)
head(dgelist_filt$samples)
head(dgelist$samples)

###########################################################################
# 11 Calculate normalisation factors using Trimmed Mean of M-values (TMM) #
###########################################################################

# With edgeR, counts are not transformed in any way after
# calculating normalisation factors
dgelist_norm <- calcNormFactors(dgelist_filt, method = "TMM")
head(dgelist_norm$samples)

#######################
# 12 Save .RData file #
#######################

save.image(file = paste0("miRNAseq_", method, ".RData", sep = ""))

##########################
# 13 Save R session info #
##########################

devtools::session_info()

######################################
# Proceed to Part 2 of this analysis #
######################################

# File: 02-miRNAseq_miRDeep2.R













