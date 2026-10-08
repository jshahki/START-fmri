#!/bin/bash
#SBATCH --job-name=reslice_bold
#SBATCH --account=st-toddwood-1
#SBATCH --nodes=1
#SBATCH --time=15:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=100G
#SBATCH --output=logs/reslice_%A_%a.out
#SBATCH --error=logs/reslice_%A_%a.err

set -euo pipefail

module purge
module load gcc/9.4.0
module load matlab/R2024b

export MATLAB_PREFDIR="$SLURM_TMPDIR/matlab_prefs"
mkdir -p "$MATLAB_PREFDIR"
mkdir -p logs

REPO_DIR="/scratch/st-toddwood-1/$USER/START-fmri"
SPLIT_INPUT_DIR="$REPO_DIR/derivatives/split"
RESLICE_OUTPUT_DIR="$REPO_DIR/derivatives/resliced"
SPM_PATH="$REPO_DIR/tools/spm-25.01.02"
REFERENCE_SCAN="$REPO_DIR/tools/3x3x3_reference_scan.nii"
PARTICIPANTS="$REPO_DIR/data/participants.tsv"

mapfile -t SUBJECTS < <(tail -n +2 "$PARTICIPANTS" | cut -f1 | sed 's/\r//')
SUBJECT="${SUBJECTS[$SLURM_ARRAY_TASK_ID]}"

if [ -z "$SUBJECT" ]; then
    echo "No subject found for index $SLURM_ARRAY_TASK_ID"
    exit 1
fi

SUBJ_INPUT_DIR="$SPLIT_INPUT_DIR/$SUBJECT"
SUBJ_OUTPUT_DIR="$RESLICE_OUTPUT_DIR/$SUBJECT"

mkdir -p "$SUBJ_OUTPUT_DIR"

# --- Detect whether input contains subfolders ---
SUBDIRS=($(find "$SUBJ_INPUT_DIR" -mindepth 1 -maxdepth 1 -type d))

if [ ${#SUBDIRS[@]} -eq 0 ]; then
    echo "[$SUBJECT] No subdirectories detected — processing .nii files directly in subject folder."

    matlab -nodisplay -r "addpath('$SPM_PATH'); spm('Defaults','fMRI'); spm_jobman('initcfg'); subj_dir = '$SUBJ_INPUT_DIR'; out_dir = '$SUBJ_OUTPUT_DIR'; ref = '$REFERENCE_SCAN'; mkdir(out_dir); files = dir(fullfile(subj_dir, '*bold_*.nii')); for i = 1:length(files); src = fullfile(subj_dir, files(i).name); spm_reslice({ref, src}, struct('which',1,'interp',4,'wrap',[0 0 0],'mask',0,'mean',0)); movefile(fullfile(subj_dir, ['r' files(i).name]), fullfile(out_dir, ['r_' files(i).name])); end; exit;"

else
    echo "[$SUBJECT] Subdirectories detected — processing each session folder separately."

    for SUBDIR in "${SUBDIRS[@]}"; do

        SUBDIR_NAME=$(basename "$SUBDIR")
        OUT_SUBDIR="$SUBJ_OUTPUT_DIR/$SUBDIR_NAME"

        mkdir -p "$OUT_SUBDIR"

        echo "Processing $SUBDIR_NAME ..."
        echo "Input:  $SUBDIR"
        echo "Output: $OUT_SUBDIR"

        # ------------------------------------------
        # Copy rp*.txt files, if they exist
        # ------------------------------------------

        RP_FILES=("$SUBDIR"/rp*.txt)
        if [ -e "${RP_FILES[0]}" ]; then
            echo "Found motion files:"
            for RP_FILE in "${RP_FILES[@]}"; do
                echo "  $RP_FILE"
                cp "$RP_FILE" "$OUT_SUBDIR/"
            done
        else
            echo "No rp*.txt files found in $SUBDIR"
        fi

        # ------------------------------------------
        # Reslice BOLD files
        # ------------------------------------------

        matlab -nodisplay -r "addpath('$SPM_PATH'); spm('Defaults','fMRI'); spm_jobman('initcfg'); subj_dir = '$SUBDIR'; out_dir = '$OUT_SUBDIR'; ref = '$REFERENCE_SCAN'; mkdir(out_dir); files = dir(fullfile(subj_dir, '*bold_*.nii')); for i = 1:length(files); src = fullfile(subj_dir, files(i).name); spm_reslice({ref, src}, struct('which',1,'interp',4,'wrap',[0 0 0],'mask',0,'mean',0)); movefile(fullfile(subj_dir, ['r' files(i).name]), fullfile(out_dir, ['r_' files(i).name])); end; exit;"

    done

fi

# --- Write success log ---
STATUS_FILE="$REPO_DIR/logs/status/${SUBJECT}_reslice_SUCCESS.txt"
mkdir -p "$(dirname "$STATUS_FILE")"
{
    echo "Subject: $SUBJECT"
    echo "Job ID: $SLURM_JOB_ID"
    echo "Completed: $(date)"
} > "$STATUS_FILE"

