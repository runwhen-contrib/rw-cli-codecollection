#!/bin/bash
# ======================================================================================
# Synopsis: a script for generating markdown files from python docstrings in a chosen directory

function main (){
    src_dir=$1
    md_dir=$2
    pyfiles=$(find "$src_dir" -name "*.py" | grep -v "__init__")
    echo "Generating documentation for files:"
    echo "$pyfiles"
    for pyfile in $pyfiles; do
        module_path=$(echo "$pyfile" | sed -e 's|/|.|g' -e 's|.py$||')
        markdown_path="${pyfile%.py}.md"
        markdown_filename=$(basename "$markdown_path")
        pydoc-markdown -m $module_path > $md_dir$markdown_filename
    done
}
main "$@"