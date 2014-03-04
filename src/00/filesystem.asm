;; deleteFile [Filesystem]
;;  Deletes a file.
;; Inputs:
;;  DE: Path to file (string pointer)
;; Outputs:
;;  Z: Set if file was deleted, reset if file did not exist
; TODO: Use a proper error code
deleteFile:
    push hl
    push af
        call findFileEntry
        jr nz, ++_
        ; Delete file
        push bc
            ld b, a
            ld a, i
            push af
                di
                ld a, b
                setBankA
                call unlockFlash
                ld a, fsDeletedFile
                call writeFlashByte
                call lockFlash
            pop af
            jp po, _
            ei
_:      pop bc
    pop af
    pop hl
    cp a
    ret
_:  ; File not found
    ld h, a
    pop af
    or 1
    ld a, h
    pop hl
    ret

;; fileExists [Filesystem]
;;  Determines if a file exists.
;; Inputs:
;;  DE: Path to file (string pointer)
;; Outputs:
;;  Z: Set if file exists, reset if not
fileExists:
    push hl
    push af
        call findFileEntry
        jr nz, _
    pop af
    pop hl
    cp a
    ret
_:  ld h, a
    pop af
    or 1
    ld a, h
    pop hl
    ret

;; createFileEntry [Filesystem]
;;  Creates a new file entry in the FAT.
;; Inputs:
;;  HL: File name
;;  DE: Parent ID
;;  ABC: Length
;;  IY: Section ID
;; Returns:
;;  Z: Set on success, reset on failure
;;  A: New entry Flash page (on success); Error code (on failure)
;;  HL: New entry address relative to 0x4000 (on success)
createFileEntry:
    ; TODO: Check for file name too long
    push af
    ld a, i
    push af
    di
    push ix
    ld ix, 0
    add ix, sp
    push hl
    push de
    push bc
        call findFATEnd
        jr nz, .endOfFilesystem

.endOfTable:
        ; Write new entry here
        ld de, 0x3FFF
        scf
        push hl
            sbc hl, de
            ld b, h \ ld c, l
        pop hl
        ; BC is space left in this FAT page
        ld d, h \ ld e, l ; Save HL in DE
        ld h, (ix + -1)
        ld l, (ix + -2) ; Grab file name from stack
        push bc
            call stringLength
            inc bc ; Zero delimited
        pop hl
        push bc
            ld a, 10
            add c
            ld c, a
            jr nc, _
            inc c
_:          call cpHLBC
        pop bc
        jr c, .endOfFilesystem
        ; We're good to go, let's do this
        ; DE is the address in FAT (here, we'll modify it to be the end of the entry):
        ex de, hl
        scf
        sbc hl, bc
        push bc
            scf
            ld bc, 8
            sbc hl, bc
        pop bc
        ex de, hl
        ; BC is the length of the filename
        ; Everything else is on the stack
        ; Let's build a new entry in kernelGarbage and then write it all at once
        ld hl, kernelGarbage + 10
        add hl, bc
        ld a, fsFile 
        ld (hl), a ; Entry ID
        dec hl
        ; Increase BC to full length of entry for a moment
        push bc
            ld a, 8
            add c
            ld c, a
            jr nc, _
            inc c
_:          ; And write that length down
            ld (hl), c
            dec hl
            ld (hl), b
            dec hl
        pop bc
        ; Write parent ID
        ld a, (ix + -4)
        ld (hl), a
        dec hl
        ld a, (ix + -3)
        ld (hl), a
        dec hl
        ; Write flags (0xFF, someone else can modify it later if they want)
        ld a, 0xFF
        ld (hl), a
        dec hl
        ; File size
        ld a, (ix + -6)
        ld (hl), a
        dec hl
        ld a, (ix + -5)
        ld (hl), a
        dec hl
        ld a, (ix + 5)
        ld (hl), a
        dec hl
        ; Section ID
        push iy \ pop bc
        ld (hl), c
        dec hl
        ld (hl), b
        dec hl
        ld b, (ix + -1)
        ld c, (ix + -2) ; Grab file name from stack
        push de
            ld de, 0
.nameLoop:
            ld a, (bc)
            ld (hl), a
            dec hl
            inc bc
            inc de
            or a ; cp 0
            jr nz, .nameLoop
            ld b, d \ ld c, e
        pop de
        ; Grab full length of entry
        ld a, 11
        add c
        ld c, a
        jr nc, _
        inc b
_:      ; Write to flash
        inc hl
        call unlockFlash
        call writeFlashBuffer
        call lockFlash

        ex de, hl ; Return HL with file entry address
        add hl, bc
        dec hl
        getBankA
        ld (ix + 5), a ; And return A with Flash page
    pop bc
    pop de
    inc sp \ inc sp ; Skip HL
    pop ix
    pop af
    jp po, _
    ei
_:  pop af
    cp a
    ret

.endOfFilesystem:
    pop bc
    pop de
    pop hl
    pop af
    jp po, _
    ei
_:  pop af
    pop ix
    or 1
    ld a, errFilesystemFull
    ret

; Internal function - finds the end of the FAT, swaps that page in, and leaves HL for you to use
findFATEnd:
    ; Find end of FAT
    ld d, fatStart
    ld a, d
    setBankA
    ld hl, 0x7FFF
.search:
    ld a, (hl)
    cp fsEndOfTable
    jr z, .endOfTable
    dec hl
    ld c, (hl)
    dec hl
    ld b, (hl)
    scf
    sbc hl, bc ; Skip to next entry
    ld a, 0x40
    cp h
    jr c, .search
    ; Swap in next page of FAT
    dec d
    ld a, d
    cp fatStart - 4
    jp z, .exitError
    setBankA
    ld hl, 0x7FFF
    jr .search
.endOfTable:
    cp a
    ret
.exitError:
    or 1
    ret

;; findFileEntry [Filesystem]
;;  Finds a file entry in the FAT.
;; Inputs:
;;  DE: Path to file (string pointer)
;; Outputs:
;;  Z: Set on success, reset on failure
;;  A: Flash page (on success); Error code (on failure)
;;  HL: Address relative to 0x4000 (on success)
findFileEntry:
    push de
    push bc
    push af
    ld a, i
    push af ; Save interrupt state
    di
        ; Skip initial / if present
        ; TODO: Allow for relative paths somehow
        ld a, (de)
        cp '/'
        jr nz, _
        inc de
_:      setBankA(fatStart)
        ld hl, 0
        ld (kernelGarbage), hl ; Used as temporary storage of parent directory ID
        ld hl, 0x7FFF
        push af
            push de \ call checkForRemainingSlashes \ pop de
            jp z, findFileEntry_fileLoop
_:          ld a, (hl)
            dec hl \ ld c, (hl) \ dec hl \ ld b, (hl) \ dec hl
            cp fsDirectory
            jr z, .handleDirectory
            cp fsSymLink ; TODO
            cp fsEndOfTable
            jr z, findFileEntry_handleEndOfTable
.continueSearch:
            or a
            sbc hl, bc
            ; TODO: Handle running off the page
            jr -_
.handleDirectory:
            push bc
                push hl
                    ld c, (hl) \ dec hl \ ld b, (hl)
                    ld hl, (kernelGarbage)
                    call cpHLBC
                    jr z, .compareNames
                    ; Not correct parent
                pop hl
            pop bc
            jr .continueSearch
.compareNames:
                    pop hl \ push hl
                    ld bc, 5
                    or a
                    sbc hl, bc
                    push de
                        call compareDirectories
                        jr z, .updateDirectory
                    pop de
                pop hl
            pop bc
            jr .continueSearch
.updateDirectory:
                    inc sp \ inc sp
                    inc de
                    push de \ call checkForRemainingSlashes \ pop de
                pop hl \ push hl
                    dec hl \ dec hl
                    ld c, (hl) \ dec hl \ ld b, (hl)
                    ld h, b \ ld l, c
                    ld (kernelGarbage), hl
                pop hl
            pop bc
            jr nz, .continueSearch
            or a
            sbc hl, bc
            jr findFileEntry_fileLoop
findFileEntry_handleEndOfTable:
        pop af
    pop af ; Restore interrupts
    jp po, _
    ei
_:  pop af
    ld a, errFileNotFound
    or a ; Resets z
    pop bc
    pop de
    ret
findFileEntry_fileLoop:
            ; Run once we've eliminated all slashes in the path
_:          ld a, (hl)
            dec hl \ ld c, (hl) \ dec hl \ ld b, (hl) \ dec hl
            cp fsFile
            jr z, .handleFile
            cp fsSymLink ; TODO
            cp fsEndOfTable
            jr z, findFileEntry_handleEndOfTable
.continueSearch:
            or a
            sbc hl, bc
            jr -_
.handleFile:
            push bc
                push hl
                    ; 0xCeck parent directory ID
                    ld c, (hl) \ dec hl \ ld b, (hl)
                    ld hl, (kernelGarbage)
                    call cpHLBC
                    jr z, .compareNames
                    ; Not correct parent
                pop hl
            pop bc
            jr .continueSearch
.compareNames:
                pop hl \ push hl
                    ld bc, 8
                    or a
                    sbc hl, bc
                    push de
                        call compareFileStrings
                    pop de
                pop hl
            pop bc
            jr z, .fileFound
            jr .continueSearch
.fileFound:
            ld bc, 3
            add hl, bc
        pop bc ; pop af
    pop af ; pop af
    jp po, _
    ei
_:  pop af
    ld a, b
    pop bc
    pop de
    cp a
    ret


; 0xcecks string at (DE) for '/'
; Z for no slashes, NZ for slashes
checkForRemainingSlashes:
    ld a, (de)
    or a ; CP 0
    ret z
    cp '/'
    jr z, .found
    inc de
    jr checkForRemainingSlashes
.found:
    or a
    ret

; Compare string, but also allows '/' as a delimiter.  Also compares HL in reverse.
; Z for equal, NZ for not equal
; HL = backwards string
; DE = fowards string
compareDirectories:
    ld a, (de)
    or a
    jr z, .return
    cp '/'
    jr z, .return
    cp ' '
    jr z, .return
    cp (hl)
    ret nz
    dec hl
    inc de
    jr compareDirectories
.return:
    ld a, (hl)
    or a
    ret

; Compare File Strings (HL is reverse)
; Z for equal, NZ for not equal
; Inputs: HL and DE are strings to compare
compareFileStrings:
    ld a, (de)
    or a
    jr z, .return
    cp ' '
    jr z, .return
    cp (hl)
    ret nz
    dec hl
    inc de
    jr compareFileStrings
.return:
    ld a, (hl)
    or a
    ret
