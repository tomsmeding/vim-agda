" ## Commands

" ### Load

" Load current file with no command-line options.
function agda#load()
  echom 'Loading Agda.'
  update

  " Start Agda job if not already started.
  if !exists('g:agda_job')
    let g:agda_job = jobstart(['agda', '--interaction-json'] + g:agda_args
      \ , {'on_stdout': function('s:handle_event')})
  endif

  let s:code_file = expand('%:p')
  let s:code_window = winnr()

  call s:send('Cmd_load'
    \ . ' "' . s:code_file . '"'
    \ . ' []'
    \ )
endfunction

" ### Environment

" Display context for hole at cursor.
function agda#environment()
  let l:id = s:lookup()

  if l:id < 0
    return
  endif

  call s:send('Cmd_goal_type_context'
    \ . ' Normalised'
    \ . ' ' . l:id
    \ . ' noRange'
    \ . ' ""'
    \ )
endfunction

" ### Give

" Give expression for hole at cursor.
function agda#give()
  let l:id = s:lookup()

  if l:id < 0
    return
  endif

  let l:input = s:escape(input('Give: '))

  if l:input ==# ''
    return
  endif

  call s:send('Cmd_give'
    \ . ' WithoutForce'
    \ . ' ' . l:id
    \ . ' noRange'
    \ . ' "' . l:input . '"'
    \ )
endfunction

" ### Refine

" Refine expression for hole at cursor.
function agda#refine()
  let l:id = s:lookup()

  if l:id < 0
    return
  endif

  let l:input = s:escape(input('Refine: '))

  call s:send('Cmd_refine_or_intro'
    \ . ' False'
    \ . ' ' . l:id
    \ . ' noRange'
    \ . ' "' . l:input . '"'
    \ )
endfunction

" ### Unused

" Check for unused code in the current module.
function agda#unused()
  update
  call jobstart(['agda-unused', '--local', expand('%'), '--json']
    \ , {'on_stdout': function('s:handle_unused')})
endfunction

" Send command to the Agda job.
function s:send(command)
  call s:handle_loading(1)
  call chansend(g:agda_job
    \ , 'IOTCM'
    \ . ' "' . s:code_file . '"'
    \ . ' None'
    \ . ' Direct'
    \ . ' (' . a:command . ')'
    \ . "\n"
    \ )
endfunction

" ## Handlers

" ### Event

" Callback function for the Agda job.
function s:handle_event(id, data, event)
  for l:line in a:data
    call s:handle_line(l:line)
  endfor
endfunction

" Callback function for the agda-unused job.
function s:handle_unused(id, data, event)
  " Check if output is non-empty; return if not.
  if len(a:data) == 0
    return
  endif

  " Decode JSON; return if unsuccessful.
  try
    let l:json = json_decode(a:data[0])
  catch
    return
  endtry

  " Handle output.
  if l:json.type ==# 'none'
    silent! bdelete Agda
    echom trim(l:json.message)
  elseif l:json.type ==# 'unused'
    call s:handle_output('Unused', l:json.message)
  elseif l:json.type ==# 'error'
    call s:handle_output('Unused', l:json.message)
  endif
endfunction

" ### Line

" Handle a line of data from Agda.
function s:handle_line(line)
  " Ignore interaction prompt.
  if a:line ==# 'JSON> '
    let s:data = ''
    return
  endif

  " Try decoding JSON; store line if decoding JSON fails.
  try
    let l:json = json_decode(s:data . a:line)
  catch
    let s:data .= a:line
    return
  endtry

  " Reset data if decoding JSON succeeds.
  let s:data = ''

  " Handle goals.
  if l:json.kind ==# 'DisplayInfo' && l:json.info.kind ==# 'AllGoalsWarnings'
    call s:handle_goals_all
      \ ( l:json.info.visibleGoals
      \ , l:json.info.invisibleGoals
      \ , l:json.info.warnings
      \ , l:json.info.errors
      \ )

  " Handle errors.
  elseif l:json.kind ==# 'DisplayInfo' && l:json.info.kind ==# 'Error'
    call s:handle_output('Error', l:json.info.message)

  " Handle context.
  elseif l:json.kind ==# 'DisplayInfo' && l:json.info.kind ==# 'GoalSpecific'
    call s:handle_environment(l:json.info.goalInfo)

  " Handle introduction not found error.
  elseif l:json.kind ==# 'DisplayInfo' && l:json.info.kind ==# 'IntroNotFound'
    call s:handle_loading(0)
    echom 'No introduction forms found.'

  " Handle give.
  elseif l:json.kind ==# 'GiveAction'
    call s:handle_give(l:json.giveResult.str, l:json.interactionPoint.id)

  " Handle interaction points.
  elseif l:json.kind ==# 'InteractionPoints'
    call s:handle_points(l:json.interactionPoints)

  " Handle status messages.
  elseif l:json.kind ==# 'RunningInfo'
    call s:handle_message(l:json.message)

  endif
endfunction

" ### Goals

function s:handle_goals_all(visible, invisible, warnings, errors)
  let l:types
    \ = (a:visible == [] && a:invisible == [] ? [] : ['Goals'])
    \ + (a:warnings == '' ? [] : ['Warnings'])
    \ + (a:errors == '' ? [] : ['Errors'])

  let l:outputs
    \ = (a:visible == []
    \   ? [] : [s:section('Goals', s:handle_goals(a:visible, 1))])
    \ + (a:invisible == []
    \   ? [] : [s:section('Goals (implicit)', s:handle_goals(a:invisible, 0))])
    \ + (a:warnings == ''
    \   ? [] : [s:section('Warnings', a:warnings)])
    \ + (a:errors == ''
    \   ? [] : [s:section('Errors', a:errors)])

  if l:types == []
    silent! bdelete Agda
    echom "All done."
  else
    call s:handle_output(join(l:types, ', '), join(l:outputs, ''))
  endif
endfunction

function s:handle_goals(goals, visible)
  return join(map(a:goals, 's:handle_goal(v:val, a:visible)'), '')
endfunction

function s:handle_goal(goal, visible)
  if a:goal.kind ==# 'OfType'
    let l:name = (a:visible ? '?' : '') . a:goal.constraintObj
    return s:signature(l:name, a:goal.type)

  elseif a:goal.kind ==# 'JustSort'
    return 'Sort '
      \ . a:goal.constraintObj
      \ . "\n"

  else
    return '(unrecognized goal)'

  endif
endfunction

function s:section(name, contents)
  return repeat('─', 4)
    \ . ' '
    \ . a:name
    \ . ' '
    \ . repeat('─', 58 - len(a:name))
    \ . "\n"
    \ . a:contents
    \ . "\n"
endfunction

" ### Points

" Initialize script-local points list.
function s:handle_points(points)
  let s:points = []

  " Only accept points with exactly one range.
  for l:point in a:points
    if len(l:point.range) == 1
      call add(s:points,
        \ { 'id': l:point.id
        \ , 'range': l:point.range[0]
        \ })
    endif
  endfor
endfunction

" ### Environment

function s:handle_environment(info)
  let l:output
    \ = s:signature('Goal', a:info.type)
    \ . repeat('─', 64)
    \ . "\n"
    \ . s:handle_entries(a:info.entries)

  call s:handle_output('Environment', l:output)
endfunction

function s:handle_entries(entries)
  return join(map(a:entries, 's:handle_entry(v:val)'), '')
    \ . "\n"
endfunction

function s:handle_entry(entry)
  let l:name = a:entry.reifiedName . (a:entry.inScope ? '' : ' (not in scope)')
  return s:signature(l:name, a:entry.binding)
endfunction

" ### Give

function s:handle_give(result, id)
  for l:point in s:points
    if l:point.id == a:id
      call s:replace(l:point.range, a:result)
      return
    endif
  endfor
endfunction

" ### Message

function s:handle_message(message)
  echom trim(substitute(a:message, '\m (.*)', '', 'g'))
endfunction

" ### Output

" Print the given output in the Agda buffer.
function s:handle_output(type, output)
  " Clear echo area.
  echo ''

  " Save initial window.
  let l:current = winnr()

  " Switch to Agda buffer.
  let l:agda = bufwinnr('Agda')
  if l:agda >= 0
    execute l:agda . 'wincmd w'
  else
    belowright 10split Agda
    let &l:buftype = 'nofile'
    let &l:swapfile = 0
  endif

  " Change buffer name.
  execute 'file Agda (' . a:type . ')'

  " Write output.
  let &l:readonly = 0
  silent %delete _
  silent put =a:output
  execute 'normal! ggdd'
  let &l:readonly = 1

  " Restore original window.
  execute l:current . 'wincmd w'
endfunction

" Display loading status in Agda buffer name.
" A status of 1 indicates loading.
" A status of 0 indicates not loading.
function s:handle_loading(status)
  " Save initial window.
  let l:current = winnr()

  " Get Agda buffer window.
  let l:agda = bufwinnr('Agda')
  if l:agda < 0
    return
  endif

  " Change Agda buffer name, if necessary.
  execute l:agda . 'wincmd w'
  let l:file = expand('%')
  let l:match = match(l:file, '\m \[loading\]$')
  if a:status == 0 && l:match >= 0 
    execute 'file ' . l:file[: l:match - 1]
  elseif a:status > 0 && l:match < 0
    execute 'file ' . l:file . ' [loading]'
  endif

  " Restore original window.
  execute l:current . 'wincmd w'
endfunction

" ## Print

" Escape a string for passing to the Agda executable.
function s:escape(str)
  return escape(a:str, '\"')
endfunction

" Format a type signature.
function s:signature(name, type)
  return a:name
    \ . "\n"
    \ . '  : '
    \ . join(split(a:type, '\n'), "\n    ")
    \ . "\n"
endfunction

" ## Utilities

" Both arguments must be dictionaries with `line` and `col` fields.
" Return -1 if pos1 is before pos2.
" Return 1 if pos1 is after pos2.
" Return 0 if pos1 equals pos2.
function s:compare(pos1, pos2)
  if a:pos1.line < a:pos2.line
    return -1
  elseif a:pos1.line > a:pos2.line
    return 1
  elseif a:pos1.col < a:pos2.col
    return -1
  elseif a:pos1.col > a:pos2.col
    return 1
  else
    return 0
  endif
endfunction

" Get id of interaction point at cursor, or return -1 on failure.
function s:lookup()
  let l:loaded
    \ = exists('g:agda_job')
    \ && exists('s:code_file')
    \ && exists('s:code_window')
    \ && exists('s:points')

  if !l:loaded
    echom 'Agda not loaded.'
    return -1
  elseif expand('%:p') !=# s:code_file
    echom 'Agda loaded on different file.'
    return -1
  endif

  let l:current =
    \ { 'line': line('.')
    \ , 'col': col('.')
    \ }

  for l:point in s:points
    if s:compare(l:current, l:point.range.start) >= 0
      \ && s:compare(l:current, l:point.range.end) <= 0
      return l:point.id
    endif
  endfor

  echom 'Cursor not on hole.'
  return -1
endfunction

" Replace text at the given point, preserving cursor position.
" Assume `str` does not contain any newline characters.
function s:replace(point, str)
  " Save window.
  let l:window = winnr()
  execute s:code_window . 'wincmd w'

  " Save cursor position.
  let l:line = line('.')
  let l:col = col('.')
  let l:current =
    \ { 'line': l:line
    \ , 'col': l:col
    \ }

  " Perform deletion.
  call cursor(a:point.start.line, a:point.start.col)
  if a:point.end.line == a:point.start.line
    execute 'normal! ' . (a:point.end.col - a:point.start.col + 1) . 'x'
  else
    let l:command
      \ = a:point.end.line > a:point.start.line + 1
      \ ? (a:point.start.line + 1) . ',' . (a:point.end.line - 1) . 'd'
      \ : ''
    execute 'normal! d$'
    execute l:command
    call cursor(a:point.start.line + 1, 1)
    execute 'normal! ' . a:point.end.col . 'x'
    call cursor(a:point.start.line, 1)
    execute 'normal! gJ'
  endif

  " Perform insertion.
  call cursor(a:point.start.line, a:point.start.col - 1)
  execute 'normal! a' . a:str

  " Restore cursor position.
  if s:compare(l:current, a:point.start) <= 0
    call cursor(l:line, l:col)
  elseif s:compare(l:current, a:point.end) <= 0
    call cursor(a:point.start.line, a:point.start.col)
  elseif l:line == a:point.start.line && l:line == a:point.end.line
    call cursor(a:point.start.line
      \ , l:col - (a:point.end.col - a:point.start.col + 1))
  elseif l:line == a:point.end.line
    call cursor(a:point.start.line, l:col - a:point.end.col)
  elseif a:point.end.line == a:point.start.line
    call cursor(l:line, l:col)
  else
    call cursor(l:line - (a:point.end.line - a:point.start.line - 1), l:col)
  endif

  " Restore window.
  execute l:window . 'wincmd w'
endfunction

