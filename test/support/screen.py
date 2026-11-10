"""The historical FS0 ANSI screen oracle (not a general terminal emulator)."""
import re
import unicodedata


def terminal_screen(data, width=120, height=40):
    """Reconstruct the PTY's ANSI screen, rather than matching stale diff bytes."""
    rows = [[' '] * width for _ in range(height)]
    x = y = 0
    for token in re.findall(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|.)|[^\x1b]+',
                            data.decode('utf-8', errors='replace')):
        if token.startswith('\x1b['):
            code = token[-1]
            values = token[2:-1]
            if values.startswith('?'):
                continue
            args = [int(v or 0) for v in values.split(';')]
            n = args[0] or 1
            if code in 'Hf':
                y, x = (args[0] or 1) - 1, ((args[1] or 1) if len(args) > 1 else 1) - 1
            elif code == 'A':
                y = max(0, y - n)
            elif code == 'B':
                y = min(height - 1, y + n)
            elif code in 'EF':
                y = min(height - 1, y + n) if code == 'E' else max(0, y - n)
                x = 0
            elif code == 'C':
                x = min(width - 1, x + n)
            elif code == 'D':
                x = max(0, x - n)
            elif code == 'G':
                x = n - 1
            elif code == 'J' and args[0] in (2, 3):
                rows = [[' '] * width for _ in range(height)]
            elif code == 'K' and 0 <= y < height:
                start, end = (0, width) if args[0] == 2 else ((0, x + 1) if args[0] == 1 else (x, width))
                rows[y][start:end] = [' '] * (end - start)
            elif code == 'X' and 0 <= y < height:
                rows[y][x:min(width, x + n)] = [' '] * min(n, width - x)
        elif not token.startswith('\x1b'):
            for char in token:
                if char == '\r':
                    x = 0
                elif char == '\n':
                    y = min(height - 1, y + 1)
                elif char == '\b':
                    x = max(0, x - 1)
                elif char >= ' ' and not unicodedata.combining(char):
                    if 0 <= y < height and 0 <= x < width:
                        rows[y][x] = char
                    x += 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
    return '\n'.join(''.join(row).rstrip() for row in rows)
