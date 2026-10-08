#!/bin/bash
#SBATCH --job-name=smoothing
#SBATCH --time=15:00:00
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=100G
#SBATCH --account=st-toddwood-1
#SBATCH --output=logs/smoothing_%A_%a.out
#SBATCH --error=logs/smoothing_%A_%a.err

# Load modules
set -euo pipefail

module purge
module load gcc/9.4.0
module load matlab/R2024b

export MATLAB_PREFDIR="$SLURM_TMPDIR/matlab_prefs"
mkdir -p "$MATLAB_PREFDIR"
mkdir -p logs

# Setup paths
REPO_DIR="/scratch/st-toddwood-1/$USER/START-fmri"
SPM_DIR="$REPO_DIR/tools/spm-25.01.02"
DATA_DIR="$REPO_DIR/derivatives/resliced"            # Resliced + split input dir
PARTICIPANTS="$REPO_DIR/data/participants.tsv"
SMOOTH_OUTPUT="$REPO_DIR/derivatives/smoothed"
LOG_DIR="$REPO_DIR/logs/status"
CODE_DIR="$REPO_DIR/code"

mkdir -p "$LOG_DIR" "$SMOOTH_OUTPUT"

# Get subject from array index
: "${SLURM_ARRAY_TASK_ID:=0}"
mapfile -t SUBJECTS < <(tail -n +2 "$PARTICIPANTS" | cut -f1 | tr -d '\r' | sed '/^$/d')
SUBJECT="${SUBJECTS[$SLURM_ARRAY_TASK_ID]}"

if [ -z "$SUBJECT" ]; then
  echo "No subject found for index $SLURM_ARRAY_TASK_ID"
  exit 1
fi

# Directories
IN_SUBJ_DIR="$DATA_DIR/$SUBJECT"
OUT_SUBJ_DIR="$SMOOTH_OUTPUT/$SUBJECT"
mkdir -p "$OUT_SUBJ_DIR"

# Kernel size from input or default to 8 8 8
KERNEL="${KERNEL:-8 8 8}"
echo "Running smoothing on $SUBJECT with kernel: $KERNEL"

# Get list of subdirectories inside the subject directory (excluding . and ..)
mapfile -t SUBDIRS < <(find "$IN_SUBJ_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [ ${#SUBDIRS[@]} -eq 0 ]; then

  # ==========================================================
  # Case 1: No subfolders — process files directly
  # ==========================================================

  echo "No subfolders found in $IN_SUBJ_DIR. Processing directly..."

  # ------------------------------------------
  # Copy rp*.txt files, if they exist
  # ------------------------------------------

  RP_FILES=("$IN_SUBJ_DIR"/rp*.txt)

  if [ -e "${RP_FILES[0]}" ]; then
    echo "Found motion files:"
    for RP_FILE in "${RP_FILES[@]}"; do
      echo "  $RP_FILE"
      cp "$RP_FILE" "$OUT_SUBJ_DIR/"
    done
  else
    echo "No rp*.txt files found in $IN_SUBJ_DIR"
  fi

  # ------------------------------------------
  # Run smoothing
  # ------------------------------------------

  matlab -nodisplay -nosplash -r "addpath('$SPM_DIR'); addpath('$CODE_DIR'); smoothing_spm_batch('$IN_SUBJ_DIR', '$OUT_SUBJ_DIR', '$SUBJECT', [$KERNEL]); exit"

else

  # ==========================================================
  # Case 2: Subfolders exist — process each subfolder
  # ==========================================================

  echo "Found ${#SUBDIRS[@]} subfolders in $IN_SUBJ_DIR."

  for SUBDIR in "${SUBDIRS[@]}"; do

    SUBNAME=$(basename "$SUBDIR")
    IN_RUN_DIR="$SUBDIR"
    OUT_RUN_DIR="$OUT_SUBJ_DIR/$SUBNAME"

    mkdir -p "$OUT_RUN_DIR"

    echo "Processing $SUBNAME for $SUBJECT..."
    echo "Input:  $IN_RUN_DIR"
    echo "Output: $OUT_RUN_DIR"

    # ------------------------------------------
    # Copy rp*.txt files, if they exist
    # ------------------------------------------

    RP_FILES=("$IN_RUN_DIR"/rp*.txt)

    if [ -e "${RP_FILES[0]}" ]; then
      echo "Found motion files:"
      for RP_FILE in "${RP_FILES[@]}"; do
        echo "  $RP_FILE"
        cp "$RP_FILE" "$OUT_RUN_DIR/"
      done
    else
      echo "No rp*.txt files found in $IN_RUN_DIR"
    fi

    # ------------------------------------------
    # Run smoothing
    # ------------------------------------------

    matlab -nodisplay -nosplash -r "addpath('$SPM_DIR'); addpath('$CODE_DIR'); smoothing_spm_batch('$IN_RUN_DIR', '$OUT_RUN_DIR', '${SUBJECT}_${SUBNAME}', [$KERNEL]); exit"

  done

fi

# Create status file
EXIT_CODE=$?
STATUS_FILE="$LOG_DIR/${SUBJECT}_$( [ $EXIT_CODE -eq 0 ] && echo SUCCESS || echo FAILED ).txt"

{
  echo "Subject: $SUBJECT"
  echo "Kernel: $KERNEL"
  echo "Exit Code: $EXIT_CODE"
  echo "Job ID: $SLURM_JOB_ID"
  echo "Finished: $(date)"
} > "$STATUS_FILE"
