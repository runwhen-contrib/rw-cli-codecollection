"""
"""

from typing import Tuple

def longest_balanced_curlies_sequence(s: str) -> Tuple[int, int]:
    """
    """
    stack = []
    break_flag = False
    start_idx, end_idx = -1, -1
    for char_idx, char in enumerate(s):
        if char == '{':
            if not stack:
                start_idx = char_idx
            stack.append(char)
        elif char == '}':
            if not stack:
                break_flag = True
            
            stack.pop()
            
            if not stack:
                # end of json_str
                break_flag = True
                end_idx = char_idx+1
            if break_flag:
                break
    
    return start_idx, end_idx