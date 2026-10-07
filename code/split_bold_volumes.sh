#!/bin/bash
#SBATCH --job-name=split_bold
#SBATCH --account=st-toddwood-1
#SBATCH --nodes=1
#SBATCH --time=15:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=100G
#SBATCH --output=logs/split_%A_%a.out
#SBATCH --error=logs/split_%A_%a.err

set -euo pipefail

module purge
module load gcc/9.4.0
module load apptainer/1.3.1

# ==========================
# PATH SETUP
# ==========================

REPO_DIR="/scratch/st-toddwood-1/$USER/START-fmri"

FMRIPREP_IMAGE="$REPO_DIR/tools/fmriprep-20.2.7.sif"
FMRIPREP_DIR="$REPO_DIR/derivatives/fmriprep"
SPLIT_DIR="$REPO_DIR/derivatives/split"
PARTICIPANTS="$REPO_DIR/data/participants.tsv"

# ==========================
# GET SUBJECT
# ==========================

mapfile -t SUBJECTS < <(
    tail -n +2 "$PARTICIPANTS" |
    cut -f1 |
    sed 's/\r//'
)

SUBJECT="${SUBJECTS[$SLURM_ARRAY_TASK_ID]}"

if [ -z "${SUBJECT:-}" ]; then
    echo "ERROR: No subject found for index $SLURM_ARRAY_TASK_ID"
    exit 1
fi

# ==========================
# SUBJECT DIRECTORIES
# ==========================

in_subj_dir="$FMRIPREP_DIR/$SUBJECT"
out_subj_dir="$SPLIT_DIR/$SUBJECT"

mkdir -p "$out_subj_dir"

echo "====================================="
echo "Processing subject: $SUBJECT"
echo "Input dir: $in_subj_dir"
echo "Output dir: $out_subj_dir"
echo "====================================="

# ==========================
# CHECK INPUT DIRECTORY
# ==========================

if [ ! -d "$in_subj_dir" ]; then
    echo "ERROR: Input subject directory does not exist:"
    echo "$in_subj_dir"
    exit 1
fi

# ==========================
# FIND ALL BOLD FILES
# ==========================

mapfile -t all_bold_files < <(
    find "$in_subj_dir" \
        -type f \
        -name "*_space-MNI152NLin2009cAsym_desc-preproc_bold.nii.gz" \
        | sort
)

# ==========================
# DEBUG BLOCK
# ==========================

echo "Searching in:"
echo "$in_subj_dir"

echo ""
echo "Found BOLD files:"

if [ "${#all_bold_files[@]}" -gt 0 ]; then
    printf '%s\n' "${all_bold_files[@]}"
else
    echo "NONE"
fi

echo ""
echo "Count: ${#all_bold_files[@]}"
echo ""

if [ "${#all_bold_files[@]}" -eq 0 ]; then
    echo "ERROR: No BOLD files found"
    exit 1
fi

# ==========================
# DETECT GLOBAL LABEL CONDITIONS
# ==========================

mapfile -t task_list < <(
    printf "%s\n" "${all_bold_files[@]}" |
    grep -oE "task-[^_/]+" |
    sort -u || true
)

mapfile -t ses_list < <(
    printf "%s\n" "${all_bold_files[@]}" |
    grep -oE "ses-[^_/]+" |
    sort -u || true
)

mapfile -t acq_list < <(
    printf "%s\n" "${all_bold_files[@]}" |
    grep -oE "acq-[^_/]+" |
    sort -u || true
)

mapfile -t echo_list < <(
    printf "%s\n" "${all_bold_files[@]}" |
    grep -oE "echo-[^_/]+" |
    sort -u || true
)

mapfile -t run_list < <(
    printf "%s\n" "${all_bold_files[@]}" |
    grep -oE "run-[0-9]+" |
    sort -u || true
)

multi_task=false

if [ "${#task_list[@]}" -gt 1 ]; then
    multi_task=true
fi

echo "Tasks found: ${task_list[*]:-none}"
echo "Sessions found: ${ses_list[*]:-none}"
echo "Acq found: ${acq_list[*]:-none}"
echo "Echo found: ${echo_list[*]:-none}"
echo "Runs found: ${run_list[*]:-none}"
echo ""

# ==========================
# SPLIT BOLD FUNCTION
# ==========================

process_bold_file() {

    local bold_file="$1"
    local output_dir="$2"

    mkdir -p "$output_dir"

    # ----------------------------------
    # Copy original BOLD file temporarily
    # ----------------------------------

    cp "$bold_file" "$output_dir"

    cd "$output_dir" || return 1

    local base_name
    base_name=$(basename "$bold_file" .nii.gz)

    echo "Splitting:"
    echo "$base_name"

    # ----------------------------------
    # Run FSL fslsplit
    # ----------------------------------

    apptainer exec "$FMRIPREP_IMAGE" fslsplit \
        "$base_name.nii.gz" \
        "${base_name}_tmp_" \
        -t

    # ----------------------------------
    # Check that fslsplit worked
    # ----------------------------------

    if ! ls "${base_name}_tmp_"*.nii.gz >/dev/null 2>&1; then
        echo "ERROR: fslsplit failed for:"
        echo "$base_name"
        return 1
    fi

    # ----------------------------------
    # Rename split files
    # ----------------------------------

    local i=1
    local f
    local suffix

    for f in "${base_name}_tmp_"*.nii.gz; do

        suffix=$(printf "%04d" "$i")

        mv "$f" "${base_name}_${suffix}.nii.gz"

        # ----------------------------------
        # Unzip individual volume
        # ----------------------------------

        gunzip -f "${base_name}_${suffix}.nii.gz"

        ((i++))
    done

    # ----------------------------------
    # Remove original 4D BOLD copy
    # ----------------------------------

    rm -f "$base_name.nii.gz"

    echo "Finished splitting:"
    echo "$base_name"

    return 0
}

# ==========================
# FIND CORRESPONDING CONFOUNDS
# ==========================

find_confounds_file() {

    local bold_file="$1"

    local bold_dir
    bold_dir=$(dirname "$bold_file")

    local bold_base
    bold_base=$(basename "$bold_file" .nii.gz)

    local confounds_file

    # ----------------------------------
    # Standard fMRIPrep naming:
    #
    # BOLD:
    # sub-01_task-rest_run-01_space-MNI152NLin2009cAsym_desc-preproc_bold.nii.gz
    #
    # Confounds:
    # sub-01_task-rest_run-01_desc-confounds_timeseries.tsv
    # ----------------------------------

    local confounds_base

    confounds_base="$bold_base"

    # Remove the spatial/preprocessing BOLD suffix
    confounds_base="${confounds_base/_space-MNI152NLin2009cAsym_desc-preproc_bold/}"

    confounds_file="${bold_dir}/${confounds_base}_desc-confounds_timeseries.tsv"

    if [ -f "$confounds_file" ]; then
        echo "$confounds_file"
        return 0
    fi

    # ----------------------------------
    # Fallback:
    # Search in the BOLD directory for a
    # matching desc-confounds file.
    # ----------------------------------

    local candidate

    candidate=$(find "$bold_dir" \
        -maxdepth 1 \
        -type f \
        -name "*_desc-confounds_timeseries.tsv" \
        | sort \
        | head -n 1 || true)

    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
        echo "$candidate"
        return 0
    fi

    return 1
}

# ==========================
# COPY CONFOUNDS + CREATE RP FILE
# ==========================

process_confounds_file() {

    local bold_file="$1"
    local output_dir="$2"

    local bold_base
    bold_base=$(basename "$bold_file" .nii.gz)

    echo ""
    echo "Processing confounds for:"
    echo "$bold_base"

    # ----------------------------------
    # Find corresponding confounds file
    # ----------------------------------

    local confounds_file

    if ! confounds_file=$(find_confounds_file "$bold_file"); then

        echo "WARNING: Could not find corresponding confounds file for:"
        echo "$bold_file"

        return 1
    fi

    echo "Found confounds:"
    echo "$confounds_file"

    # ----------------------------------
    # Copy original TSV to output folder
    # ----------------------------------

    cp "$confounds_file" "$output_dir/"

    local copied_confounds
    copied_confounds="$output_dir/$(basename "$confounds_file")"

    echo "Copied confounds to:"
    echo "$copied_confounds"

    # ----------------------------------
    # Create rp_*.txt
    # ----------------------------------

    local rp_file
    rp_file="$output_dir/rp_${bold_base}.txt"

    echo "Creating motion file:"
    echo "$rp_file"

    # ----------------------------------
    # Extract:
    #
    # trans_x
    # trans_y
    # trans_z
    # rot_x
    # rot_y
    # rot_z
    #
    # from the fMRIPrep TSV.
    #
    # The output:
    # - has no header
    # - has six columns
    # - is whitespace separated
    # - uses scientific notation
    # ----------------------------------

    awk -F '\t' '

    BEGIN {
        OFS=" "
    }

    # ----------------------------------
    # Read header
    # ----------------------------------

    NR == 1 {

        for (i = 1; i <= NF; i++) {

            if ($i == "trans_x")
                tx = i

            if ($i == "trans_y")
                ty = i

            if ($i == "trans_z")
                tz = i

            if ($i == "rot_x")
                rx = i

            if ($i == "rot_y")
                ry = i

            if ($i == "rot_z")
                rz = i
        }

        # ----------------------------------
        # Verify all six columns exist
        # ----------------------------------

        if (!tx || !ty || !tz || !rx || !ry || !rz) {

            print "ERROR: Could not find all six motion columns." > "/dev/stderr"

            print "Required columns:" > "/dev/stderr"
            print "trans_x" > "/dev/stderr"
            print "trans_y" > "/dev/stderr"
            print "trans_z" > "/dev/stderr"
            print "rot_x"  > "/dev/stderr"
            print "rot_y"  > "/dev/stderr"
            print "rot_z"  > "/dev/stderr"

            exit 1
        }

        next
    }

    # ----------------------------------
    # Write six motion parameters
    # ----------------------------------

    {
        printf "% .7e % .7e % .7e % .7e % .7e % .7e\n", \
            $tx, $ty, $tz, $rx, $ry, $rz
    }

    ' "$confounds_file" > "$rp_file"

    # ----------------------------------
    # Check output
    # ----------------------------------

    if [ ! -s "$rp_file" ]; then

        echo "ERROR: rp file was not created or is empty:"
        echo "$rp_file"

        return 1
    fi

    echo "Created motion file:"
    echo "$rp_file"

    echo ""
    echo "First 5 rows:"
    head -n 5 "$rp_file"

    echo ""

    return 0
}

# ==========================
# MAIN LOOP
# ==========================

successful_files=0
failed_split_files=0
failed_confounds_files=0

for f in "${all_bold_files[@]}"; do

    fname=$(basename "$f")

    # ----------------------------------
    # Extract BIDS entities
    # ----------------------------------

    ses=$(echo "$fname" | grep -oE "ses-[^_/]+" || true)

    task=$(echo "$fname" | grep -oE "task-[^_/]+" || true)

    acq=$(echo "$fname" | grep -oE "acq-[^_/]+" || true)

    echoe=$(echo "$fname" | grep -oE "echo-[^_/]+" || true)

    run=$(echo "$fname" | grep -oE "run-[0-9]+" || true)

    # ----------------------------------
    # BUILD OUTPUT NAME
    # ----------------------------------

    out_name=""

    if [ -n "$ses" ]; then
        out_name="${ses}"
    fi

    if [ "$multi_task" = true ] && [ -n "$task" ]; then

        if [ -n "$out_name" ]; then
            out_name="${out_name}_"
        fi

        out_name="${out_name}${task}"
    fi

    if [ -n "$acq" ]; then

        if [ -n "$out_name" ]; then
            out_name="${out_name}_"
        fi

        out_name="${out_name}${acq}"
    fi

    if [ -n "$echoe" ]; then

        if [ -n "$out_name" ]; then
            out_name="${out_name}_"
        fi

        out_name="${out_name}${echoe}"
    fi

    if [ -n "$run" ]; then

        if [ -n "$out_name" ]; then
            out_name="${out_name}_"
        fi

        out_name="${out_name}${run}"
    fi

    # ----------------------------------
    # If no labels were found,
    # use "default"
    # ----------------------------------

    if [ -z "$out_name" ]; then
        out_name="default"
    fi

    out_dir="$out_subj_dir/$out_name"

    mkdir -p "$out_dir"

    # ----------------------------------
    # Print information
    # ----------------------------------

    echo ""
    echo "====================================="
    echo "File:"
    echo "$fname"
    echo ""
    echo "Output folder:"
    echo "$out_dir"
    echo "====================================="
    echo ""

    # ----------------------------------
    # SPLIT BOLD
    # ----------------------------------

    if ! process_bold_file "$f" "$out_dir"; then

        echo "FAILED splitting:"
        echo "$fname"

        ((failed_split_files+=1))

        continue
    fi

    # ----------------------------------
    # COPY CONFOUNDS + CREATE RP FILE
    # ----------------------------------

    if ! process_confounds_file "$f" "$out_dir"; then

        echo "WARNING: Confounds processing failed:"
        echo "$fname"

        ((failed_confounds_files+=1))

        # Do not mark the BOLD split as failed.
        # The BOLD volumes were successfully created.

        continue
    fi

    # ----------------------------------
    # Everything succeeded
    # ----------------------------------

    ((successful_files+=1))

    echo ""
    echo "Successfully processed:"
    echo "$fname"
    echo "====================================="

done

# ==========================
# STATUS LOG
# ==========================

STATUS_FILE="$REPO_DIR/logs/status/${SUBJECT}_split_SUCCESS.txt"

mkdir -p "$(dirname "$STATUS_FILE")"

{
    echo "Subject: $SUBJECT"
    echo "Job ID: $SLURM_JOB_ID"
    echo "Completed: $(date)"
    echo ""
    echo "BOLD files found: ${#all_bold_files[@]}"
    echo "Successfully processed: $successful_files"
    echo "Failed BOLD splits: $failed_split_files"
    echo "Failed confounds processing: $failed_confounds_files"
    echo ""
    echo "Input directory: $in_subj_dir"
    echo "Output directory: $out_subj_dir"

} > "$STATUS_FILE"

# ==========================
# FINAL SUMMARY
# ==========================

echo ""
echo "====================================="
echo "Finished processing $SUBJECT"
echo "====================================="
echo "BOLD files found: ${#all_bold_files[@]}"
echo "Successfully processed: $successful_files"
echo "Failed BOLD splits: $failed_split_files"
echo "Failed confounds: $failed_confounds_files"
echo ""
echo "Status file:"
echo "$STATUS_FILE"
echo "====================================="
