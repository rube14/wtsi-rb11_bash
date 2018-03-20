#!/bin/bash

. /software/npg/etc/profile.npg
. /software/sanger-samtools-refpath/etc/profile.sanger-samtools-refpath


usage(){
    cat <<-EOF
	This script generates VTFP templates using the information provided by a targets file.
	[M]ethods available:  bwa_mem | bwa_aln | tophat2 | bam2cram | y_split | hs_split | salmon | bam2salmon
	Output, input, json and staging directories are defined relative to ./ or a working directory provided by -w, and
	if -m runfolder is used, their values will be generated by the script and -[ijos] will be ignored.
	
	Usage: 
	
	$0 -M <METHOD> [options] <targets_file.txt
	
	Options:
	   -c <number>      Do not use WTSI composite id (run_position[#tag]), use insted the
	                    contents of this column in the targets file (must be unique).
	   -f <format>      Input file format: cram | bam. Default: auto-detect.
	   -h               Show usage message.
	   -i <directory>   Input directory. Default: ./input/.
	   -j <directory>   Output direcory for json file. Default: ./json/.
	   -m <method hint> Shortcut for specific directory structure: <runfolder | reanalysis>.
	   -n <number>      If -m runfolder is used, numeric part of tmp_XXXXX folder
	   -o <directory>   Output directory. Default: ./output/<method>/<run>/<run_pos#tag>/.
	   -r <directory>   Absolute path to repository for reference genome/transcriptome/.
	   -s <directory>   Staging directory. Default: ./staging/<method>/<run>/<run_pos#tag>/.
	   -t <dir|file>    P4 template file or directory where templates can be located. Default: <P4_PATH>/data/vtlib/.
	   -w <directory>   Absolute path to working directory. Default: $PWD.
	   -x <extra args>  Extra arguments passed to vtfp in a quoted string (-k/-v pairs).
	EOF

}

# function to print messages
# to STDOUT or STDERR
exitmessage(){
    declare EXITMESG=$1
    declare EXITCODE=$2
    if [ $EXITCODE -eq 0 ]; then
        >&1 printf '%s\n' "$EXITMESG"
    else
        >&2 printf '%s\n' "$EXITMESG"
    fi
    exit $EXITCODE
}

#set -x

if [ $# -lt 1 ]; then
    usage; 
    exit 1
fi

while getopts ":c:i:j:f:hm:M:m:n:o:r:s:t:w:x:" OPTION; do
    case $OPTION in
        c)
            TARGETSCOLUMN=$OPTARG
            [[ ! $TARGETSCOLUMN =~ ^[0-9]+$ ]] && exitmessage "[ERROR] -c: not a digit: ${TARGETSCOLUMN}" 1;;
        f)
            FORMAT=$OPTARG;;
        h)
            usage; exit 1;;
        i)
            INPUTDIR=$OPTARG;;
        j)
            JSONDIR=$OPTARG;;
        o)
            OUTPUTDIR=$OPTARG;;
        M)
            METHOD=$OPTARG
            METHODREGEX="^bam2cram|star|tophat2|bwa\_aln|bwa\_mem|hs\_split|y\_split|salmon$"
            [[ ! $METHOD =~ $METHODREGEX ]] && exitmessage "[ERROR] -M: invalid method $METHOD: try '$0 -h' for more information" 1;;
        m)
            METHODHINT=$OPTARG
            METHODHINTREGEX="^runfolder|reanalysis$"
            [[ ! $METHODHINT =~ $METHODHINTREGEX ]] && exitmessage "[ERROR] -m: invalid method hint $METHODHINT: try '$0 -h' for more information" 1;;
        n)
            TMPDIRNUM=$OPTARG
            [[ ! $TMPDIRNUM =~ ^[0-9]+$ ]] && exitmessage "[ERROR] -n: not a digit: ${TMPDIRNUM}" 1;;
        r)
            REPOSITORY=$OPTARG
            [[ ! -d $REPOSITORY ]] && exitmessage "[ERROR] -w: Cannot access ${REPOSITORY}: no such directory" 2
            [[ ! $REPOSITORY = /* ]] && exitmessage "[ERROR] -w: Not an absolute path" 1;;
        s)
            STAGINGDIR=$OPTARG;;
        t)
            TEMPLATEDIRORFILE=$OPTARG;;
        w)
            CWD=$OPTARG
            [[ ! -d $CWD ]] && exitmessage "[ERROR] -w: Cannot access ${CWD}: no such directory" 2
            [[ ! $CWD = /* ]] && exitmessage "[ERROR] -w: Not an absolute path" 1;;
        x)
            EXTRAKEYVALS=$OPTARG;;
        \?)
            exitmessage "[ERROR] Invalid option: -$OPTARG" 1;;
        :)
            exitmessage "[ERROR] Option -$OPTARG requires an argument." 1;;
    esac
done



if env | grep -q ^P4_PATH=
then
    # use whatever version of p4 you defined like this:
    # export P4_PATH=/nfs/users/nfs_r/rb11/dev/perl/wtsi-npg_p4
    printf -- "[INFO] Using P4_PATH=$P4_PATH\n"
    BINARY="${P4_PATH}/bin/vtfp.pl"
else
    # for production stuff e.g. remapping, use production versions
    # for development/experimental/non-deployed stuff e.g. bam2cram use own repo (see path above)
    if [ $METHOD = "bam2cram" ]; then
        exitmessage "[ERROR] Not P4_PATH env variable: try 'export P4_PATH=/path/to/p4'" 1
    else
        BINARY=$(readlink -f `which vtfp.pl`)
        export P4_PATH=${BINARY%/bin*}
    fi
fi


if [ -d "$TEMPLATEDIRORFILE" ]; then
    CFGDATADIR="$TEMPLATEDIRORFILE"
elif [ -f "$TEMPLATEDIRORFILE" ]; then
    ALIGNMENTTEMPLATE="$TEMPLATEDIRORFILE"
fi

CFGDATADIR="${CFGDATADIR:-"${P4_PATH}/data/vtlib"}"
VTFPEXECUTABLE="$BINARY"
WORKINGDIR="${CWD:-"$PWD"}"

[ -e "${OUTJSONDIR}/vtfp_commands_${METHOD}.log" ] && rm -f "${OUTJSONDIR}/vtfp_commands_${METHOD}.log"

COUNTTOTAL=0
COUNTOK=0
COUNTFAIL=0

while read line; do

    # Read info from targets file
    if [ ! -z $TARGETSCOLUMN ]; then
        BAMID=`echo "$line" | awk -v column=$TARGETSCOLUMN -F'\t' '{print $column}'`
    else
        RUN=`echo "$line" | awk -F'\t' '{print $2}'`
        POSITION=`echo "$line" | awk -F'\t' '{print $3}'`
        TAG=`echo "$line" | awk -F'\t' '{print $4}'`
        # deal with non-multiplexed lanes
        if [ -z $TAG ]; then
            BAMID="${RUN}_${POSITION}"
        else
            BAMID="${RUN}_${POSITION}#${TAG}"
        fi
    fi
    ALIGNMENTSINBAM=`echo "$line" | awk -F'\t' '{print $5}'`
    ALIGNREFGENOME=`echo "$line" | awk -F'\t' '{print $6}'`
    REFDICTNAME=`echo "$line" | awk -F'\t' '{print $7}'`
    REFNAMEFASTA=`echo "$line" | awk -F'\t' '{print $8}'`
    TRANSCRIPTOME=`echo "$line" | awk -F'\t' '{print $9}'`
    TRANSCRIPTANNO=`echo "$line" | awk -F'\t' '{print $10}'`
    LIBRARYTYPE=`echo "$line" | awk -F'\t' '{print $11}'`
    LIBRARYLAYOUT=`echo "$line" | awk -F'\t' '{print $12}'`
    REFTRANSCRIPTFASTA=`echo "$line" | awk -F'\t' '{print $13}'`

    if [ "$METHODHINT" = "reanalysis" ]; then
        IBAMDIR="input/${RUN}"
        OBAMDIR="output/${METHOD}/${RUN}/${BAMID}"
        SBAMDIR="staging/${METHOD}/${RUN}/${BAMID}"
        JDIR="json"
    elif [ "$METHODHINT" = "runfolder" ]; then
        IBAMDIR="no_cal/lane${POSITION}"
        OBAMDIR="no_cal/archive/lane${POSITION}"
        if [ -z "$TMPDIRNUM" ]; then
            exitmessage "[ERROR] -n: a numeric value is required for -n when -m runfolder is being used (numbers in tmp_XXXXXX directory)"
        else
            SBAMDIR="no_cal/archive/tmp_${TMPDIRNUM}/${BAMID}"
            JDIR="no_cal/archive/tmp_${TMPDIRNUM}/${BAMID}"
        fi
        OUTJSONDIR="${WORKINGDIR}/${JDIR}"
        [ -d "$OUTJSONDIR" ] || exitmessage "[ERROR] Cannot access ${OUTJSONDIR}: No such directory" 2
        OUTDATADIR="${WORKINGDIR}/${OBAMDIR}"
        [ -d "$OUTDATADIR" ] || exitmessage "[ERROR] Cannot access ${OUTDATADIR}: No such directory" 2
        OUTSTAGINGDIR="${WORKINGDIR}/${SBAMDIR}"
        [ -d $OUTSTAGINGDIR ] || exitmessage "[ERROR] Cannot access ${OUTSTAGINGDIR}: No such directory" 2
    else
        IBAMDIR="${INPUTDIR:-"input/$RUN"}"
        OBAMDIR="${OUTPUTDIR:-"output/$METHOD/$RUN/$BAMID"}"
        SBAMDIR="${STAGINGDIR:-"staging/$METHOD/$RUN/$BAMID"}"
        JDIR="${JSONDIR:-"json"}"
    fi

    OUTJSONDIR="${WORKINGDIR}/${JDIR}"
    [ ! -d "$OUTJSONDIR" ] && exitmessage "[ERROR] Cannot access ${OUTJSONDIR}: No such directory" 2
    OUTDATADIR="${WORKINGDIR}/${OBAMDIR}"
    [ ! -d "$OUTDATADIR" ] && printf -- "[WARNING] Cannot access ${OUTDATADIR}: No such directory\n" 2
    INDATADIR="${WORKINGDIR}/${IBAMDIR}"
    [ ! -d "$INDATADIR" ] && exitmessage "[ERROR] Cannot access ${INDATADIR}: No such directory" 2
    OUTSTAGINGDIR="${WORKINGDIR}/${SBAMDIR}"
    [ ! -d "$OUTSTAGINGDIR" ] && printf -- "[WARNING] Cannot access ${OUTSTAGINGDIR}: No such directory\n" 2
    
    SRCINPUT="${INDATADIR}/${BAMID}"   #extension-less input file name
    REPOSDIR="${REPOSITORY-"/lustre/scratch117/core/sciops_repository"}"
    PHIXDICTNAME="PhiX/default/all/picard/phix_unsnipped_short_no_N.fa.dict"
    PHIXREFNAME="PhiX/Sanger-SNPs/all/fasta/phix_unsnipped_short_no_N.fa"
    ALIGNMENTFILTERJAR="/software/solexa/pkg/illumina2bam/1.19/AlignmentFilter.jar"
    ALIGNMENTMETHOD=$METHOD

    case $METHOD in
        *salmon|star|tophat2)
            if [ "$METHOD" = "tophat2" ]; then
                if [[ ! $TRANSCRIPTOME = NoTranscriptome ]]; then
                    TOPHAT2_ARGS="-keys transcriptome_val "
                    # full or relative path should be OK
                    [[ ! $TRANSCRIPTOME = /* ]] && TOPHAT2_ARGS+="-vals ${REPOSDIR}/transcriptomes/${TRANSCRIPTOME} " || TOPHAT2_ARGS+="-vals ${TRANSCRIPTOME} "
                elif  [[ ! $TRANSCRIPTANNO = NoTranscriptome ]]; then
                    TOPHAT2_ARGS+="-keys annotation_val " #only when there's no transcriptome index for tophat
                    [[ ! $TRANSCRIPTOME = /* ]] && TOPHAT2_ARGS+="-vals ${REPOSDIR}/transcriptomes/${TRANSCRIPTANNO} " || TOPHAT2_ARGS+="-vals ${TRANSCRIPTANNO} "
                else
                    exitmessage "[ERROR] NoTranscriptome for Tophat2 alignment" 1
                fi
                [[ $LIBRARYTYPE =~ dUTP ]] && TOPHAT2_ARGS+="-keys library_type -vals fr-firststrand" || TOPHAT2_ARGS+="-keys library_type -vals fr-unstranded"
            elif [ "$METHOD" = "star" ]; then
                STAR_ARGS="-keys annotation_val -vals ${REPOSDIR}/transcriptomes/${TRANSCRIPTANNO} "
                STAR_ARGS+="-keys sjdb_overhang_val -vals 74 "
                STAR_ARGS+="-keys star_executable -vals star "
                if [[ ! $ALIGNREFGENOME =~ .*/star$ ]]; then
                    ALIGNREFGENOME="$(dirname $ALIGNREFGENOME)"
                    ALIGNREFGENOME="$(dirname $ALIGNREFGENOME)"
                    ALIGNREFGENOME+="/star"
                fi
            elif [ "$METHOD" = "salmon" ]; then #just 'salmon'
                SALMON_ARGS+="-keys annotation_val "
                [[ ! $TRANSCRIPTANNO = /* ]] && SALMON_ARGS+="-vals ${REPOSDIR}/transcriptomes/${TRANSCRIPTANNO} " || SALMON_ARGS+="-vals ${TRANSCRIPTANNO} "
            fi
            SALMON_TRANSCRIPTOME="$(dirname $TRANSCRIPTOME)"
            SALMON_TRANSCRIPTOME="$(dirname $SALMON_TRANSCRIPTOME)"
            SALMON_TRANSCRIPTOME+="/salmon"
            if [[ ! $TRANSCRIPTOME = NoTranscriptome && ! $TRANSCRIPTANNO = NoTranscriptome ]]; then
                SALMON_ARGS="-keys salmon_transcriptome_val "
                # full or relative path should be OK
                [[ ! $TRANSCRIPTOME = /* ]] && SALMON_ARGS+="-vals ${REPOSDIR}/transcriptomes/${SALMON_TRANSCRIPTOME} " || SALMON_ARGS+="-vals ${SALMON_TRANSCRIPTOME} "
            else
                exitmessage "[ERROR] NoTranscriptome for Salmon quantification" 1
            fi
            SALMON_ARGS+="-keys quant_method -vals salmon "
            ;;
        hs_split)
            ALIGNMENTMETHOD=bwa_mem
            ALIGNMENTTEMPLATE="${ALIGNMENTTEMPLATE:-"${CFGDATADIR}/realignment_wtsi_stage2_humansplit_template.json"}"
            HS_SPLIT_ARGS="-keys reference_dict_hs -vals ${REPOSDIR}/references/Homo_sapiens/1000Genomes/all/picard/human_g1k_v37.fasta.dict "
            HS_SPLIT_ARGS+="-keys hs_reference_genome_fasta -vals ${REPOSDIR}/references/Homo_sapiens/1000Genomes/all/fasta/human_g1k_v37.fasta "
            HS_SPLIT_ARGS+="-keys hs_alignment_reference_genome -vals ${REPOSDIR}/references/Homo_sapiens/1000Genomes/all/bwa0_6/human_g1k_v37.fasta "
            HS_SPLIT_ARGS+="-keys alignment_filter_jar -vals /software/solexa/pkg/illumina2bam/1.17/AlignmentFilter.jar "
            HS_SPLIT_ARGS+="-keys alignment_hs_method -vals bwa_aln "
            ;;
        y_split)
            ALIGNMENTMETHOD=bwa_mem
            # 20170609: in p4 0.18.6 bambi is used instead of illumina2bam. Is this by default?
            Y_SPLIT_ARGS="-keys split_bam_by_chromosomes_jar -vals /software/solexa/pkg/illumina2bam/1.17/SplitBamByChromosomes.jar "
            Y_SPLIT_ARGS+="-keys final_output_prep_target_name -vals split_by_chromosome "
            Y_SPLIT_ARGS+="-keys split_indicator -vals _yhuman "
            Y_SPLIT_ARGS+="-keys split_bam_by_chromosome_flags -vals S=Y "
            Y_SPLIT_ARGS+="-keys split_bam_by_chromosome_flags -vals V=true "
            Y_SPLIT_ARGS+="-keys s2b_mt_val -vals 7 "
            ;;
    esac

    if [ -e "${SRCINPUT}.cram" ]; then
        SRCINPUTEXT="cram"
    elif [ -e "${SRCINPUT}.bam" ]; then
        SRCINPUTEXT="bam"
    elif [ -e "${SRCINPUT}.sam" ]; then
        SRCINPUTEXT="sam"
    else
        printf -- "[ERROR] ${BAMID}: No bam or cram or sam file was found in ${INDATADIR}/\n"
        exitmessage "[INFO] Use option -i to specify an input directory relative to ${WORKINGDIR}" 1
    fi

    ######################
    # Generate JSON files
    ######################
    printf -- "[INFO] Generating [${METHOD}] json file for [${ALIGNMENTSINBAM}] [${BAMID}] in [./${OUTJSONDIR}/${BAMID}_${METHOD}.json] with source format [${SRCINPUTEXT}]\n"
    [ ! -z "$EXTRAKEYVALS" ] && printf -- "[INFO] Using extra arguments [ ${EXTRAKEYVALS} ]\n"

    # start building vtfp command
    VTFP_CMD="${VTFPEXECUTABLE} -l ${OUTJSONDIR}/vtfp_${BAMID}_${METHOD}.log "
    VTFP_CMD+="-ve 3 "
    VTFP_CMD+="-o ${OUTJSONDIR}/${BAMID}_${METHOD}.json "
    VTFP_CMD+="-keys rpt -vals ${BAMID} "
    VTFP_CMD+="-keys src_input_ext -vals ${SRCINPUTEXT} "
    VTFP_CMD+="-keys src_input_format -vals ${SRCINPUTEXT} "
    VTFP_CMD+="-keys outdatadir -vals ${OUTDATADIR} "
    VTFP_CMD+="-keys indatadir -vals ${INDATADIR} "
    VTFP_CMD+="-keys cfgdatadir -vals ${CFGDATADIR} "
    
    case $METHOD in
        bwa_aln|bwa_mem|tophat2|star|hs_split|y_split)
            # bwa args apply to all of these methods
            BWA_ARGS="-keys bwa_executable -vals bwa0_6 "
            [ "$LIBRARYLAYOUT" = "SINGLE" ] && BWA_ARGS+="-nullkeys bwa_mem_p_flag"

            # templates used for these methods
            if [ "$ALIGNMENTSINBAM" = "aligned" ]; then
                ALIGNMENTTEMPLATE="${ALIGNMENTTEMPLATE:-"${CFGDATADIR}/realignment_wtsi_template.json"}"
            else
                ALIGNMENTTEMPLATE="${ALIGNMENTTEMPLATE:-"${CFGDATADIR}/alignment_wtsi_stage2_template.json"}"
            fi

            # for realignment at least this prunning has to be there, more can be included in the -x option
            [[ $EXTRAKEYVALS =~ prune ]] && PRUNE_NODES_ARGS="" || PRUNE_NODES_ARGS="-prune_nodes fop.*samtools_stats_F0.*00_bait.*-"

            VTFP_CMD+="-keys samtools_executable -vals samtools "
            VTFP_CMD+="-keys alignment_method -vals ${ALIGNMENTMETHOD} "
            VTFP_CMD+="-keys af_metrics -vals ${BAMID}.bam_alignment_filter_metrics.json "
            VTFP_CMD+="-keys reference_dict -vals ${REPOSDIR}/references/${REFDICTNAME} "
            VTFP_CMD+="-keys reference_genome_fasta -vals ${REPOSDIR}/references/${REFNAMEFASTA} "
            VTFP_CMD+="-keys alignment_reference_genome -vals ${REPOSDIR}/references/${ALIGNREFGENOME} "
            VTFP_CMD+="-keys phix_reference_genome_fasta -vals ${REPOSDIR}/references/${PHIXREFNAME} "
            VTFP_CMD+="-keys alignment_filter_jar -vals ${ALIGNMENTFILTERJAR} "
            VTFP_CMD+="-keys aligner_numthreads -vals 16 "
            VTFP_CMD+="-keys br_numthreads_val -vals 7 "
            VTFP_CMD+="-keys b2c_mt_val -vals 7 "
            VTFP_CMD+="-keys s2b_mt_val -vals 7 "
            VTFP_CMD+="${TOPHAT2_ARGS} ${STAR_ARGS} ${SALMON_ARGS} ${HS_SPLIT_ARGS} ${Y_SPLIT_ARGS} ${BWA_ARGS} "

            EXPORT_PV_JSON="-export_param_vals ${OUTJSONDIR}/${BAMID}_p4_${ALIGNMENTMETHOD}_realignment_pv_out.json "
            ;;
        *salmon)
            # exclusive templates for these methods
            if [ "$METHOD" = "bam2salmon" ]; then
                ALIGNMENTTEMPLATE="${ALIGNMENTTEMPLATE:-"bam_to_salmon.json"}"
            elif [ "$METHOD" = "salmon" ]; then
                ALIGNMENTTEMPLATE="${ALIGNMENTTEMPLATE:-"salmon.json"}"
            else
                exitmessage "[ERROR] -M: option not supported: $METHOD" 1
            fi

            VTFP_CMD+="${SALMON_ARGS} "

            EXPORT_PV_JSON="-export_param_vals ${OUTJSONDIR}/${BAMID}_p4_${METHOD}_pv_out.json "
            ;;
        bam2cram)
            exitmessage "[ERROR] -M: option bam2cram not supported for now: $METHOD" 1
            ;;
        *)
           exitmessage "[ERROR] -M: option not supported: $METHOD" 1 
    esac

    # final touches to the vtfp command
    VTFP_CMD+="${EXTRAKEYVALS} ${PRUNE_NODES_ARGS} ${EXPORT_PV_JSON} ${ALIGNMENTTEMPLATE}"
    
    echo $VTFP_CMD >> "${OUTJSONDIR}/vtfp_commands_${METHOD}.log"
        
    RET_CODE=0
    VTFP="$($VTFP_CMD 2>&1)"
    RET_CODE=$?
    
    let COUNTTOTAL+=1
    COUNTBAMID+=("$BAMID")
 
    if [ "$RET_CODE" -eq 0 ] && [ -z "$VTFP" ]; then
        let COUNTOK+=1
    else
        printf -- "[INFO] VTFP command for [ ${BAMID} ] exited with exit code ${RET_CODE}\n"
        printf -- "[ERROR] $VTFP\n"
        let COUNTFAIL+=1
    fi
     
done < /dev/stdin

COUNTUNIQ=`tr ' ' '\n' <<< "${COUNTBAMID[@]}" | sort -u | wc -l`

if [ "$COUNTTOTAL" -gt "$COUNTUNIQ" ]; then
    MESSAGEDUPS=" or are duplicated"
    COUNTOK=$COUNTUNIQ
    let COUNTFAIL="$COUNTFAIL + ($COUNTTOTAL - $COUNTUNIQ)"
fi

if [ "$COUNTTOTAL" -eq "$COUNTOK" ]; then
    MESSAGE="Done. [ ${COUNTOK} ] command(s) executed successfully"
    RET_CODE=0
else
    MESSAGE="[ ${COUNTFAIL} ] command(s) exited with errors ${MESSAGEDUPS}"
    RET_CODE=1
fi

exitmessage "[INFO] $MESSAGE" $RET_CODE
