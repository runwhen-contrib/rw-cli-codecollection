"""
This module provides functionality to find and extract the longest balanced
sequence of curly braces from a given string. This is commonly useful for
parsing JSON-like structures or other brace-delimited content where you need
to identify complete, properly nested brace pairs.

The module uses a stack-based approach to track opening and closing braces,
ensuring that the extracted sequence is properly balanced (every opening
brace has a corresponding closing brace in the correct order).
"""

from typing import Tuple

def longest_balanced_curlies_sequence(s: str) -> Tuple[int, int]:
    """
    Find the longest balanced sequence of curly braces in a string.
    
    This function scans through a string and identifies the first complete
    balanced sequence of curly braces. A balanced sequence means that every
    opening brace '{' has a corresponding closing brace '}' and they are
    properly nested.
    
    :param s: The input string to search for balanced curly braces
    :type s: str
    :returns: A tuple containing the start index (inclusive) and end index 
              (exclusive) of the balanced sequence. Returns (-1, -1) if no 
              balanced sequence is found.
    :rtype: Tuple[int, int]
    """
    stack = []                           # keep track of opening braces - helps us match pairs
    break_flag = False                   # indicates whether to stop processing
    start_idx, end_idx = -1, -1
    for char_idx, char in enumerate(s):
        if char == '{':
            if not stack:                # start of new curly-brace sequence
                start_idx = char_idx
            stack.append(char)
        elif char == '}':
            if not stack:
                break_flag = True        # No matching opening brace - this is an invalid sequence, Set flag to break out of loop
            else:
                stack.pop()              # remove matching opening brace
            
            if not stack:                # end of json_str
                break_flag = True
                end_idx = char_idx+1
            if break_flag:
                break
    
    return start_idx, end_idx