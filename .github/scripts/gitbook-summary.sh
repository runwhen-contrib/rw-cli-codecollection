#!/bin/bash
# ======================================================================================
# Synopsis: Generates the gitbook summary for the codecollection so no manual
#           adjustments are required for gitbook updates

function main (){
    output_file="SUMMARY.md"

    echo "# Summary" > "$output_file"
    echo "" >> "$output_file"

    # Generate Codebundles section
    echo "## Codebundles" >> "$output_file"
    find codebundles -name "README.md" | while read -r file; do
        # Extract the directory name as title
        title=$(basename $(dirname "$file"))
        # Print markdown link format
        echo "* [$title]($file)" >> "$output_file"
    done
    echo "" >> "$output_file"

    # Generate Keywords section
    echo "## Keywords" >> "$output_file"
    find libraries/.docs -name "*.md" | grep -Ev "Suggest|local_process" | while read -r file; do
        # Exclude the main README.md if needed
        if [ "$file" != "${dir_adjustment}libraries/.docs/README.md" ]; then
            # Extract the filename without extension as title
            title=$(basename "$file" .md)
            # Print markdown link format
            echo "* [$title]($file)" >> "$output_file"
        fi
    done


    # Notify user of completion
    echo "README summary generated in $output_file"

    return $?
}
main "$@"