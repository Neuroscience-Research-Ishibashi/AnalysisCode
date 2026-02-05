#!/bin/bash
# ============================================
# Artur's fMRI Quality Control Script
# ============================================

# ---- PROMPT FOR INPUTS ----
read -p "Enter fMRI NIfTI file (e.g., sub-01_task-rest.nii or .nii.gz): " INPUT_FMRI
read -p "Enter brain mask file (e.g., brainmask.nii.gz): " INPUT_MASK
read -p "Enter Subject ID (for report): " SUBJECT_ID

if [ ! -f "$INPUT_FMRI" ]; then
    echo "ERROR: Input file '$INPUT_FMRI' not found!"
    exit 1
fi

if [ ! -f "$INPUT_MASK" ]; then
    echo "ERROR: Mask file '$INPUT_MASK' not found!"
    exit 1
fi

BASENAME=$(basename "$INPUT_FMRI")
BASENAME_NOEXT=${BASENAME%%.nii*}

echo "============================================"
echo "Starting fMRI Quality Control"
echo "Input: $INPUT_FMRI"
echo "Mask:  $INPUT_MASK"
echo "Subject: $SUBJECT_ID"
echo "============================================"

# Create output directory
OUTPUT_DIR="${SUBJECT_ID}_QC_Results"
mkdir -p "$OUTPUT_DIR"

# Initialize log file
LOG_FILE="$OUTPUT_DIR/processing_log.txt"
echo "Processing started: $(date)" > "$LOG_FILE"
echo "Input file: $INPUT_FMRI" >> "$LOG_FILE"
echo "Mask file: $INPUT_MASK" >> "$LOG_FILE"

# Function to check if command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        echo "✓ $1" | tee -a "$LOG_FILE"
    else
        echo "✗ Failed: $1" | tee -a "$LOG_FILE"
    fi
}

# ============================================================================
# STEP 1: FILE PREPARATION AND BASIC INFO
# ============================================================================
echo ""
echo "=== STEP 1: Checking files and basic info ==="

# Create compressed version for FSL
echo "Creating compressed version for FSL..."
cp "$INPUT_FMRI" "$OUTPUT_DIR/original_fmri.nii"
gzip -f "$OUTPUT_DIR/original_fmri.nii"
FMRI_FILE="$OUTPUT_DIR/original_fmri.nii.gz"
MASK_FILE="$INPUT_MASK"

# Get basic file information
echo "Getting file information..."
fslinfo "$FMRI_FILE" > "$OUTPUT_DIR/file_info.txt"
check_status "File info extraction"

# Get number of volumes
NUM_VOLUMES=$(fslnvols "$FMRI_FILE")
echo "Number of volumes: $NUM_VOLUMES" | tee -a "$LOG_FILE"

# Get dimensions
DIMENSIONS=$(fslinfo "$FMRI_FILE" | grep "^dim[123]" | tr '\n' ' ')
echo "Dimensions: $DIMENSIONS" | tee -a "$LOG_FILE"

# ============================================================================
# STEP 2: MOTION CORRECTION
# ============================================================================
echo ""
echo "=== STEP 2: Motion correction ==="

echo "Running mcflirt (this may take a while)..."
mcflirt -in "$FMRI_FILE" \
        -out "$OUTPUT_DIR/mc_fmri" \
        -plots \
        -rmsrel \
        -rmsabs \
        -report \
        -stats \
        -spline_final \
        -dof 6

check_status "Motion correction"

# If .par file exists, rename it to standard name
if [ -f "$OUTPUT_DIR/mc_fmri.par" ]; then
    cp "$OUTPUT_DIR/mc_fmri.par" "$OUTPUT_DIR/motion_params.par"
    echo "Found motion parameters: mc_fmri.par" | tee -a "$LOG_FILE"
elif [ -f "$OUTPUT_DIR/mc_fmri.mat" ]; then
    echo "Found .mat file, converting to parameters..."
    avscale --allparams "$OUTPUT_DIR/mc_fmri.mat" > "$OUTPUT_DIR/motion_params.txt" 2>/dev/null
fi

# ============================================================================
# STEP 3: BASIC STATISTICS AND tSNR
# ============================================================================
echo ""
echo "=== STEP 3: Calculating basic statistics and tSNR ==="

# Create mean functional image
echo "Creating mean functional image..."
fslmaths "$OUTPUT_DIR/mc_fmri.nii.gz" -Tmean "$OUTPUT_DIR/mean_func.nii.gz"
check_status "Mean image creation"

# Create standard deviation image
echo "Creating standard deviation image..."
fslmaths "$OUTPUT_DIR/mc_fmri.nii.gz" -Tstd "$OUTPUT_DIR/std_func.nii.gz"
check_status "Std image creation"

# Calculate tSNR
echo "Calculating tSNR..."
fslmaths "$OUTPUT_DIR/mean_func.nii.gz" -div "$OUTPUT_DIR/std_func.nii.gz" "$OUTPUT_DIR/tsnr.nii.gz"
check_status "tSNR calculation"

# Apply brain mask to tSNR
echo "Applying brain mask to tSNR..."
fslmaths "$OUTPUT_DIR/tsnr.nii.gz" -mas "$MASK_FILE" "$OUTPUT_DIR/tsnr_masked.nii.gz"
check_status "Mask application"

# Calculate statistics
echo "Calculating statistics..."
fslstats "$OUTPUT_DIR/tsnr_masked.nii.gz" -M -S -R > "$OUTPUT_DIR/tsnr_stats.txt"
echo "tSNR statistics:" | tee -a "$LOG_FILE"
cat "$OUTPUT_DIR/tsnr_stats.txt" | tee -a "$LOG_FILE"

# ============================================================================
# STEP 4: MOTION ANALYSIS
# ============================================================================
echo ""
echo "=== STEP 4: Motion analysis ==="

# Framewise Displacement
echo "Calculating Framewise Displacement..."
fsl_motion_outliers -i "$FMRI_FILE" \
                    -o "$OUTPUT_DIR/fd_outliers.txt" \
                    -s "$OUTPUT_DIR/fd_values.txt" \
                    -p "$OUTPUT_DIR/fd_plot" \
                    --fd \
                    -v

check_status "Framewise Displacement calculation"

# DVARS
echo "Calculating DVARS..."
fsl_motion_outliers -i "$OUTPUT_DIR/mc_fmri.nii.gz" \
                    -o "$OUTPUT_DIR/dvars_outliers.txt" \
                    -s "$OUTPUT_DIR/dvars_values.txt" \
                    -p "$OUTPUT_DIR/dvars_plot" \
                    --dvars \
                    -v

check_status "DVARS calculation"

# ============================================================================
# STEP 7: QUALITY METRICS CALCULATION
# (keeping numbering from original, but only metrics needed for final HTML)
# ============================================================================
echo ""
echo "=== STEP 7: Calculating quality metrics ==="

# Mean intensity
MEAN_INT=$(fslstats "$OUTPUT_DIR/mean_func.nii.gz" -M)
echo "Mean intensity: $MEAN_INT" | tee -a "$LOG_FILE"

# Mean tSNR
MEAN_tSNR=$(fslstats "$OUTPUT_DIR/tsnr_masked.nii.gz" -M)
echo "Mean tSNR: $MEAN_tSNR" | tee -a "$LOG_FILE"

# FD statistics
if [ -f "$OUTPUT_DIR/fd_values.txt" ]; then
    MEAN_FD=$(awk '{sum+=$1} END {if(NR>0) print sum/NR; else print "NA"}' "$OUTPUT_DIR/fd_values.txt")
    MAX_FD=$(sort -n "$OUTPUT_DIR/fd_values.txt" | tail -1)
    FD_OUTLIERS=$(awk '$1 > 0.5 {count++} END {print count+0}' "$OUTPUT_DIR/fd_values.txt")
    echo "Mean FD: $MEAN_FD mm" | tee -a "$LOG_FILE"
    echo "Max FD: $MAX_FD mm" | tee -a "$LOG_FILE"
    echo "FD outliers (>0.5mm): $FD_OUTLIERS" | tee -a "$LOG_FILE"
else
    MEAN_FD="NA"
    MAX_FD="NA"
    FD_OUTLIERS="0"
fi

# DVARS statistics
if [ -f "$OUTPUT_DIR/dvars_values.txt" ]; then
    DVARS_OUTLIERS=$(wc -l < "$OUTPUT_DIR/dvars_outliers.txt" 2>/dev/null || echo "0")
    echo "DVARS outliers: $DVARS_OUTLIERS" | tee -a "$LOG_FILE"
else
    DVARS_OUTLIERS="0"
fi

# Overall quality classification for summary line
QUALITY_LABEL="GOOD - Data appears to be of high quality."

# ============================================================================
# STEP 8: GENERATE STYLED MINIMAL HTML REPORT
# ============================================================================
echo ""
echo "=== STEP 8: Generating styled HTML report ==="

REPORT_HTML="$OUTPUT_DIR/QC_Report_${SUBJECT_ID}.html"

cat > "$REPORT_HTML" << EOF
<html>
<head>
    <title>fMRI QC Report - $SUBJECT_ID</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; color: #2c3e50; }
        h1 { color: #2c3e50; margin-bottom: 5px; }
        h2 { color: #3498db; border-bottom: 2px solid #eee; padding-bottom: 6px; margin-top: 30px; }
        .section-title { font-weight: bold; margin-top: 25px; margin-bottom: 8px; }
        .meta { margin-bottom: 20px; }
        .meta p { margin: 2px 0; }
        table { border-collapse: collapse; width: 100%; margin: 10px 0 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; font-weight: bold; }
        .metric-block { background: #f8f9fa; padding: 10px 15px; border-radius: 5px; margin: 10px 0 15px 0; }
        .metric-title { font-weight: bold; margin-bottom: 4px; }
        .good { color: #27ae60; font-weight: bold; }
        .warning { color: #f39c12; font-weight: bold; }
        .bad { color: #e74c3c; font-weight: bold; }
        hr { margin-top: 30px; margin-bottom: 10px; border: none; border-top: 1px solid #ddd; }
        .footer { font-style: italic; color: #7f8c8d; margin-top: 10px; }
    </style>
</head>
<body>
    <h1>fMRI Quality Control Report</h1>
    <div class="meta">
        <p><strong>Subject:</strong> $SUBJECT_ID</p>
        <p><strong>Analysis Date:</strong> $(date)</p>
        <p><strong>Input File:</strong> $INPUT_FMRI</p>
    </div>

    <h2>1. Basic Information</h2>
    <table>
        <tr><th>Parameter</th><th>Value</th></tr>
        <tr><td>Number of Volumes</td><td>$NUM_VOLUMES</td></tr>
        <tr><td>Dimensions</td><td>$DIMENSIONS</td></tr>
        <tr><td>Processing Date</td><td>$(date)</td></tr>
    </table>

    <h2>2. Quality Metrics</h2>

    <div class="metric-block">
        <div class="metric-title">Temporal Signal-to-Noise Ratio (tSNR)</div>
        <p>Mean tSNR:
            <span class="$(
                if [ "$(echo "$MEAN_tSNR > 30" | bc)" -eq 1 ]; then
                    echo good
                elif [ "$(echo "$MEAN_tSNR > 20" | bc)" -eq 1 ]; then
                    echo good
                elif [ "$(echo "$MEAN_tSNR > 10" | bc)" -eq 1 ]; then
                    echo warning
                else
                    echo bad
                fi
            )">$MEAN_tSNR</span>
        </p>
        <p>Interpretation:
            $(
                if [ "$(echo "$MEAN_tSNR > 30" | bc)" -eq 1 ]; then
                    echo "Excellent"
                elif [ "$(echo "$MEAN_tSNR > 20" | bc)" -eq 1 ]; then
                    echo "Good"
                elif [ "$(echo "$MEAN_tSNR > 10" | bc)" -eq 1 ]; then
                    echo "Acceptable"
                else
                    echo "Poor"
                fi
            )
        </p>
    </div>

    <div class="metric-block">
        <div class="metric-title">Motion Analysis</div>
        <p>Mean Framewise Displacement:
            <span class="$(
                if [ "$MEAN_FD" != "NA" ] && [ "$(echo "$MEAN_FD < 0.2" | bc)" -eq 1 ]; then
                    echo good
                elif [ "$MEAN_FD" != "NA" ] && [ "$(echo "$MEAN_FD < 0.3" | bc)" -eq 1 ]; then
                    echo warning
                else
                    echo warning
                fi
            )">$MEAN_FD mm</span>
        </p>
        <p>Maximum FD:
            <span class="$(
                if [ "$MAX_FD" != "NA" ] && [ "$(echo "$MAX_FD < 0.5" | bc)" -eq 1 ]; then
                    echo good
                else
                    echo warning
                fi
            )">$MAX_FD mm</span>
        </p>
        <p>Volumes with FD > 0.5mm: $FD_OUTLIERS</p>
    </div>

    <div class="metric-block">
        <div class="metric-title">Signal Characteristics</div>
        <p>Mean Intensity: $MEAN_INT</p>
        <p>DVARS Outliers: $DVARS_OUTLIERS</p>
    </div>

    <h2>5. Summary</h2>
    <p>
        Overall Data Quality:
        <span class="good">$QUALITY_LABEL</span>
    </p>

    <hr>
    <p class="footer">Report generated by Artur's fMRI QC Pipeline</p>
</body>
</html>
EOF

check_status "Report generation"

echo ""
echo "============================================"
echo "QC PROCESSING COMPLETE!"
echo "============================================"
echo "Output directory: $OUTPUT_DIR/"
echo "HTML report: $REPORT_HTML"
echo "Processing log: $LOG_FILE"
echo "============================================"