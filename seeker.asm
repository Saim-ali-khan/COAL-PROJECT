;  Usage:
;    ./ngrep <filename> <pattern> [--regex]

;  Pattern rules (when --regex is given, or always for wildcard mode):
;    *   zero or more of ANY character
;    .   exactly ONE character
;  Without --regex the pattern is treated as a plain literal string.
;


global _start

section .data
    msg_usage       db  "Usage: ngrep <filename> <pattern> [--regex]", 0x0A
    msg_usage_len   equ $ - msg_usage

    msg_open_err    db  "Error: cannot open file", 0x0A
    msg_open_len    equ $ - msg_open_err

    flag_regex      db  "--regex", 0

section .bss
    BUF_SIZE        equ 65536
    filebuf         resb BUF_SIZE

    LINE_SIZE       equ 4096
    linebuf         resb LINE_SIZE

    fd              resq 1

    parse_ptr       resq 1

    bytes_in_buf    resq 1

    use_regex       resb 1


section .text

_start:
    pop     rax
    cmp     rax, 3
    jl      .usage_and_exit

    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx

    mov     r12, rdx
    mov     r13, rsi
    mov     r14, rcx

    mov     byte [use_regex], 0
    test    r14, r14
    jz      .open_file
    cmp     rax, 4
    
    call    str_eq_flag
    jnz     .open_file
    mov     byte [use_regex], 1

.open_file:
    mov     rax, 2
    mov     rdi, r13
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .open_error
    mov     [fd], rax

    call    process_file

    mov     rax, 3
    mov     rdi, [fd]
    syscall

    mov     rax, 60
    xor     rdi, rdi
    syscall

.usage_and_exit:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_usage
    mov     rdx, msg_usage_len
    syscall
    mov     rax, 60
    mov     rdi, 1
    syscall

.open_error:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_open_err
    mov     rdx, msg_open_len
    syscall
    mov     rax, 60
    mov     rdi, 1
    syscall


;  flag checker
;  str_eq_flag
;  Compares the C-string at r14 with "--regex"
;  Returns: ZF set (jz taken) if equal, ZF clear if not.

str_eq_flag:
    push    rsi
    push    rdi
    push    rcx
    mov     rsi, r14
    mov     rdi, flag_regex
    
.loop:
    mov     al, [rsi]
    mov     bl, [rdi]
    cmp     al, bl
    jne     .not_equal
    test    al, al
    jz      .equal
    inc     rsi
    inc     rdi
    jmp     .loop
.equal:
    xor     eax, eax
    test    eax, eax
    pop     rcx
    pop     rdi
    pop     rsi
    ret
.not_equal:
    mov     eax, 1
    test    eax, eax
    pop     rcx
    pop     rdi
    pop     rsi
    ret


; ___________________________________________________________
;  process_file
;  Reads the file in BUF_SIZE chunks, splits on newlines,
;  and for each complete line calls match_and_print.
;
;  r12 = pattern  (preserved throughout)
; ___________________________________________________________
process_file:
    push    rbp
    push    rbx
    push    r15

    xor     r15, r15

.fill_buf:
    mov     rax, 0
    mov     rdi, [fd]
    mov     rsi, filebuf
    mov     rdx, BUF_SIZE
    syscall
    test    rax, rax
    jle     .eof

    mov     [bytes_in_buf], rax
    mov     qword [parse_ptr], filebuf

.parse_loop:
    mov     rbx, filebuf
    add     rbx, [bytes_in_buf]
    cmp     qword [parse_ptr], rbx
    jge     .fill_buf

    mov     rsi, [parse_ptr]
    mov     al, [rsi]
    inc     qword [parse_ptr]

    cmp     al, 0x0A
    je      .end_of_line

    cmp     r15, LINE_SIZE - 1
    jge     .parse_loop

    mov     rdi, linebuf
    add     rdi, r15
    mov     [rdi], al
    inc     r15
    jmp     .parse_loop

.end_of_line:
    mov     rdi, linebuf
    add     rdi, r15
    mov     byte [rdi], 0

    mov     rdi, linebuf
    mov     rsi, r15
    mov     rdx, r12
    call    match_and_print

    xor     r15, r15
    jmp     .parse_loop

.eof:
    test    r15, r15
    jz      .done

    mov     rdi, linebuf
    add     rdi, r15
    mov     byte [rdi], 0

    mov     rdi, linebuf
    mov     rsi, r15
    mov     rdx, r12
    call    match_and_print

.done:
    pop     r15
    pop     rbx
    pop     rbp
    ret



;  match_and_print
;  rdi = pointer to line (NUL-terminated)
;  rsi = line length
;  rdx = pattern (NUL-terminated)
;
;  Calls the appropriate matcher, then prints the line + newline
;  if there is a match.

match_and_print:
    push    rbp
    push    r15
    push    r14
    push    r13
    push    r12

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx

    cmp     byte [use_regex], 1
    je      .do_wildcard

    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    literal_search
    jmp     .check_result

.do_wildcard:
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    wildcard_search

.check_result:
    test    rax, rax
    jz      .no_match

    mov     rax, 1
    mov     rdi, 1
    mov     rsi, r12
    mov     rdx, r13
    syscall

    push    0x0A
    mov     rax, 1
    mov     rdi, 1
    mov     rsi, rsp
    mov     rdx, 1
    syscall
    pop     rax

.no_match:
    pop     r12
    pop     r13
    pop     r14
    pop     r15
    pop     rbp
    ret



;  literal_search
;  Brute-force O(n*m) substring search (no wildcards).
;
;  rdi = text ptr
;  rsi = text length
;  rdx = pattern ptr (NUL-terminated)
;
;  Returns rax = 1 if found, 0 if not.

literal_search:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx

    call    strlen_rdx
    mov     r15, rax

    test    r15, r15
    jz      .found

    xor     rbx, rbx
.outer:
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, r15
    jl      .not_found

    xor     rcx, rcx
.inner:
    cmp     rcx, r15
    jge     .found

    mov     r8, r12
    add     r8, rbx
    mov     al, [r8 + rcx]
    mov     dl, [r14 + rcx]
    cmp     al, dl
    jne     .mismatch

    inc     rcx
    jmp     .inner

.mismatch:
    inc     rbx
    jmp     .outer

.found:
    mov     rax, 1
    jmp     .done
.not_found:
    xor     rax, rax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; helper: strlen of NUL-terminated string at rdx → rax
strlen_rdx:
    xor     rax, rax
.sl:
    cmp     byte [rdx + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl
.sl_done:
    ret


; ________________________________________________________________
;  wildcard_search
;  Tries to match pattern (with * and .) anywhere inside text.
;  Strategy: for each starting position s in text, call
;  wildcard_match(text+s, pattern). Return 1 on first hit.
;
;  rdi = text ptr
;  rsi = text length
;  rdx = pattern ptr (NUL-terminated)
;
;  Returns rax = 1 if found, 0 if not.
; ________________________________________________________________
wildcard_search:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx

    xor     rbx, rbx

.outer:
    cmp     rbx, r13
    jg      .not_found

    mov     rdi, r12
    add     rdi, rbx
    mov     rsi, r13
    sub     rsi, rbx
    mov     rdx, r14
    call    wildcard_match
    test    rax, rax
    jnz     .found

    inc     rbx
    jmp     .outer

.found:
    mov     rax, 1
    jmp     .done
.not_found:
    xor     rax, rax
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ______________________________________________________________
;  wildcard_match  (recursive via stack, brute-force)
;  Checks if pattern matches a PREFIX of the given text.
;  '*' matches zero or more characters.
;  '.' matches exactly one character.
;
;  rdi = text ptr   (NOT necessarily NUL-terminated, use length)
;  rsi = text length remaining
;  rdx = pattern ptr (NUL-terminated)
;
;  Returns rax = 1 if matches, 0 if not.
;
;  Uses a simple iterative approach with backtracking stored on
;  the call stack via recursion for '*'.
; _______________________________________________________________
wildcard_match:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx

.loop:
    mov     al, [r14]
    test    al, al
    jz      .pat_end

    cmp     al, '*'
    je      .star

    test    r13, r13
    jz      .no_match

    cmp     al, '.'
    je      .dot

    mov     bl, [r12]
    cmp     al, bl
    jne     .no_match

.dot:
    inc     r12
    dec     r13
    inc     r14
    jmp     .loop

.star:
    inc     r14

    xor     rbx, rbx
.star_loop:
    push    r12
    push    r13
    push    r14
    push    rbx

    mov     rdi, r12
    add     rdi, rbx
    mov     rsi, r13
    sub     rsi, rbx
    mov     rdx, r14
    call    wildcard_match

    pop     rbx
    pop     r14
    pop     r13
    pop     r12

    test    rax, rax
    jnz     .match

    inc     rbx
    cmp     rbx, r13
    jle     .star_loop

    jmp     .no_match

.pat_end:
    test    r13, r13
    jz      .match
    jmp     .no_match

.match:
    mov     rax, 1
    jmp     .done
.no_match:
    xor     rax, rax
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret