#!/bin/bash

run_core_screening() {

    ui_section "Core scaling study"

    mkdir -p coreScalingLogs
    rm -f coreScalingLogs/coreScaling.dat

    # Read efficiency threshold from paramDict
    effThreshold=$(foamDictionary "$PARAM_DICT" -entry coreEffMin -value 2>/dev/null | tr -d '[:space:]')

    if [ -z "$effThreshold" ]; then
        effThreshold=0.5
    fi

    ui_kv "Efficiency threshold" "$effThreshold"

    for core in "${coreList[@]}"; do

        ui_info "[TEST] Running with $core core(s)"

        set_core_count "$core"

        start=$(date +%s)

        bash ./Allrun > "coreScalingLogs/${solver}_Core-${core}" 2>&1

        end=$(date +%s)
        runtime=$((end-start))

        echo "$core $runtime" >> coreScalingLogs/coreScaling.dat

        ./Allclean
    done

    ui_section "Core scaling summary"
    printf '  %-6s %-10s %-10s %-10s\n' "Core" "Time(s)" "Speedup" "Efficiency"

    # Serial time
    T1=$(awk 'NR==1 {print $2}' coreScalingLogs/coreScaling.dat)

    # Variables for decisions
    optimalCore=1
    highestAcceptable=1
    fastestCore=$(sort -k2 -n coreScalingLogs/coreScaling.dat | head -1 | awk '{print $1}')

    while read core time; do

        speedup=$(awk -v t1="$T1" -v tp="$time" 'BEGIN {printf "%.2f", t1/tp}')
        efficiency=$(awk -v s="$speedup" -v p="$core" 'BEGIN {printf "%.2f", s/p}')

        printf '  %-6s %-10s %-10s %-10s\n' "$core" "$time" "$speedup" "$efficiency"

        # Check threshold condition
        check=$(awk -v e="$efficiency" -v th="$effThreshold" 'BEGIN {print (e>=th)?1:0}')

        if [ "$check" -eq 1 ]; then
            optimalCore=$core
            highestAcceptable=$core
        fi

    done < coreScalingLogs/coreScaling.dat

    echo
    ui_kv "Efficiency threshold" "$effThreshold"
    ui_kv "Optimal production core" "$optimalCore"
    ui_kv "Highest acceptable core" "$highestAcceptable"
    ui_kv "Fastest runtime core" "$fastestCore"
    ui_kv "Scaling limit" "$highestAcceptable core(s)"

    # Fastest runtime
    fastestTime=$(sort -k2 -n coreScalingLogs/coreScaling.dat | head -1 | awk '{print $2}')

    tolerance=1.05
    optimalCore=1

    while read core time; do

        limit=$(awk -v t="$fastestTime" -v tol="$tolerance" 'BEGIN {print t*tol}')
        check=$(awk -v tp="$time" -v lim="$limit" 'BEGIN {print (tp<=lim)?1:0}')

        if [ "$check" -eq 1 ]; then
            optimalCore=$core
            break
        fi

    done < coreScalingLogs/coreScaling.dat

    ui_ok "Recommended production core: $optimalCore"

    exit 0
}
