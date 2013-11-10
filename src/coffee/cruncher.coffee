window.Cruncher = Cr = window.Cruncher || {}

$ ->
    onEquals = (cm) ->
        cursor = cm.getCursor 'end'

        cm.replaceRange '=', {
            line: cursor.line
            ch: cursor.ch
        }, {
            line: cursor.line
            ch: (cm.getLine cursor.line).length
        }

    Cr.editor = editor = null
    Cr.editor = editor = CodeMirror.fromTextArea $('#code')[0],
        lineNumbers: true
        lineWrapping: true,
        gutters: ['lineState']
        theme: 'cruncher'
        autofocus: true
        extraKeys:
            '=': onEquals

    # There are two extra properties we put on each line handle in CodeMirror.
    #     evaluating: is this line being evaluated?
    #     parsed: parse / evaluation object for the line (Equation or Expression)
    # They're attached to the handle so that they follow the line around if it moves.

    # generate unique ids for text markers
    # used in graphs so that we can have a (mark, chart) map
    CodeMirror.TextMarker.prototype.toString = do ->
        id = 0
        -> @id ? @id = id++

    getFreeMarkSpans = (line) ->
        handle = editor.getLineHandle line
        if handle?.markedSpans?
            (span for span in handle.markedSpans \
                when span.marker.className == 'free-number')
        else
            []
    
    reparseLine = (line) ->
        text = editor.getLine line
        handle = editor.getLineHandle line
       
        textToParse = text

        spans = getFreeMarkSpans line
        for span in spans
            textToParse = (textToParse.substring 0, span.from) +
                ((Array span.to - span.from + 1).join '') + # horrifying hack
                (textToParse.substring span.to)

        try
            parsed = parser.parse textToParse
            if parsed?.values?
                value.line = line for value in parsed.values
                editor.on handle, 'change', (line, changeObj) -> console.log 'line', line, changeObj
                handle.parsed = parsed
            else
                handle.parsed = null
            
            Cr.unsetLineState line, 'parseError'
            
        catch e
            console.log 'parse error', e, line, textToParse
            handle.parsed = null
            Cr.setLineState line, 'parseError'

            i = 0
            firstToken = null
            while not firstToken
                firstToken = Cr.editor.getTokenTypeAt { line: line, ch: i }
                i += 1
            if firstToken == 'equals'
                # wipe out the line, they probably deleted the entire left half
                editor.setLine line, ''

    Cr.markAsFree = markAsFree = (from, to) ->
        editor.markText from, to,
            className: 'free-number'
            inclusiveLeft: false
            inclusiveRight: false
            atomic: true

    oldCursor = null
    solveChange = (instance, changeObj) ->
        # runs while evaluating and constraining a line
        # returns weakened version of onChange handler that just makes sure
        # user's cursor stays in a sane position while we evalLine
        # 
        # e.g. {2} |+ 3 = 5 -> {20} |+ 3 = 5
        #      we shift the cursor right 1 character
        if changeObj.to.line == oldCursor.line and oldCursor.ch > changeObj.from.ch
            cursorOffset = changeObj.text[0].length - (changeObj.to.ch - changeObj.from.ch)
            newCursor =
                line: oldCursor.line
                ch: oldCursor.ch + cursorOffset
            editor.setCursor newCursor
            oldCursor = newCursor

        else
            editor.setCursor oldCursor

    Cr.evalLine = evalLine = (line) ->
        # runs after a line changes
        # (except, of course, when evalLine is the changer)
        # reconstrain the free number(s) [currently only 1 is supported]
        # so that the equation is true,
        # or make the line an equation

        reparseLine line

        Cr.unsetLineState line, stateName for stateName in \
            ['overDetermined', 'underDetermined']

        handle = editor.getLineHandle line
        
        # intercept change events for this line,
        # but pass other lines (which might be dependencies)
        # through to the normal handler
        # TODO deal with circular dependencies (this makes them undefined behavior)
        handle.evaluating = true
        oldCursor = editor.getCursor()

        text = editor.getLine line
        parsed = handle.parsed
        if parsed?.constructor == Cr.Expression # edited a line without another side (yet)
            freeString = parsed.numString()

            from =
                line: line
                ch: text.length + ' = '.length
            to =
                line: line
                ch: text.length + ' = '.length + freeString.length

            editor.replaceRange ' = ' + freeString, from
            markAsFree from, to

            reparseLine line
            
        else if parsed?.constructor == Cr.Equation
            try
                [freeValue, solution] = parsed.solve()

                # TODO come up with a nicer way
                # to preserve marks when replaceRange
                mark = (span.marker for span in getFreeMarkSpans line)[0]

                oldCursor = editor.getCursor()

                mark.inclusiveLeft = true
                mark.inclusiveRight = true

                numbersOnLine =
                    (text.substring(0, freeValue.start) + text.substring(freeValue.end))
                    .match(/[0-9\.]+/g)

                editor.replaceRange (Cr.roundSig numbersOnLine, solution),
                    (Cr.valueFrom freeValue),
                    (Cr.valueTo freeValue)

                mark.inclusiveLeft = false
                mark.inclusiveRight = false

                editor.setCursor oldCursor

                handle.equalsMark?.clear()
                reparseLine line

            catch e
                if e instanceof Cr.OverDeterminedException
                    Cr.setLineState line, 'overDetermined'
                    Cr.updateSign line, handle
                else if e instanceof Cr.UnderDeterminedException
                    Cr.setLineState line, 'underDetermined'

        handle.evaluating = false

    editor.on 'change', (instance, changeObj) ->
        if not changeObj.origin
            # automatic origin -- merge with last change
            history = editor.doc.history
            lastChange = history.done.pop()
            prevChange = history.done.pop()
            $.merge prevChange.changes, lastChange.changes
            prevChange.headAfter = lastChange.headAfter
            prevChange.anchorAfter = lastChange.anchorAfter
            history.done.push prevChange

        # executes on user or cruncher change to text
        # (except during evalLine)
        for line in [changeObj.from.line..changeObj.to.line + changeObj.text.length - 1]
            handle = editor.getLineHandle line
            continue unless handle

            if handle.evaluating
                solveChange instance, changeObj
            else
                evalLine line

        # replace all value locations that might be affected by a newline
        if changeObj.text.length > 1
            for line in [changeObj.to.line + 1..editor.lineCount() - 1]
                handle = editor.getLineHandle line
                continue unless handle.parsed?.values?

                for value in handle.parsed.values
                    value.line = line

        Cr.updateConnectionsForChange changeObj

    ($ document).on 'mouseenter', '.cm-number', Cr.startHover

    editor.refresh()

    for line in [0..editor.lineCount() - 1]
        evalLine line