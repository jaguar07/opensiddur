xquery version "1.0";

(:~ reference index module
 :
 : Manage an index of references in the /db/refindex collection
 : In this index, the keys are the referenced URI or a node
 : and the type of reference. The index stores node id's of
 : the linking elements that make the references
 :
 : Open Siddur Project
 : Copyright 2011 Efraim Feinstein <efraim.feinstein@gmail.com>
 : Licensed under the GNU Lesser General Public License, version 3 or later 
 :)
module namespace ridx = 'http://jewishliturgy.org/modules/refindex';

import module namespace app="http://jewishliturgy.org/modules/app"
  at "xmldb:exist:///code/modules/app.xqm";
import module namespace paths="http://jewishliturgy.org/modules/paths" 
  at "xmldb:exist:///code/modules/paths.xqm";
import module namespace uri="http://jewishliturgy.org/transform/uri"
  at "xmldb:exist:///code/modules/follow-uri.xqm";

declare namespace err="http://jewishliturgy.org/errors";
declare namespace tei="http://www.tei-c.org/ns/1.0";

(: the default cache is under this directory :)
declare variable $ridx:ridx-collection := "refindex";

(:~ make an index collection path that mirrors the same path in 
 : the normal /db hierarchy 
 : @param $path-base the constant base at the start of the path
 : @param $path the path to mirror
 :)
declare function local:make-mirror-collection-path(
  $path-base as xs:string,
  $path as xs:string
  ) as empty() {
  let $steps := tokenize(replace($path, '^(/db)?/', concat($path-base,"/")), '/')[.]
  for $step in 1 to count($steps)
  let $this-step := concat('/', string-join(subsequence($steps, 1, $step), '/'))
  where not(xmldb:collection-available($this-step))
  return
    let $mirror-this-step := concat("/",string-join(subsequence($steps, 2, $step - 1),"/"))
    let $previous-step := concat('/', string-join(subsequence($steps, 1, $step - 1), '/'))
    let $new-collection := $steps[$step]
    let $null := util:log-system-out(("step ", $step, ":", $this-step, " new-collection=",$new-collection, " from ", $previous-step))
    let $owner := 
      if ($step = 1)
      then "admin"
      else xmldb:get-owner($mirror-this-step)
    let $group := 
      if ($step = 1)
      then "dba"
      else xmldb:get-group($mirror-this-step)
    let $mode := 
      if ($step = 1)
      then util:base-to-integer(0770, 8)
      else xmldb:get-permissions($mirror-this-step)
    return (
      if ($paths:debug)
      then 
        util:log-system-out(('creating new index collection: ', $this-step, ' from ', $previous-step, ' to ', $new-collection ,' owner/group/permissions=', $owner, '/',$group, '/',util:integer-to-base($mode,8)))
      else (),
      if (xmldb:create-collection($previous-step, $new-collection))
      then xmldb:set-collection-permissions($this-step, $owner, $group, $mode)
      else error(xs:QName('err:CREATE'), concat('Cannot create index collection ', $this-step))
    )
};


(:~ index or reindex a document given its location by collection
 : and resource name :)
declare function ridx:reindex(
  $collection as xs:string,
  $resource as xs:string
  ) {
  ridx:reindex(doc(app:concat-path($collection, $resource)))
};

(:~ index or reindex a document from the given document node :)
declare function ridx:reindex(
  $doc as document-node()
  ) as empty() {
  let $collection := replace(util:collection-name($doc), "^/db", "")
  let $resource := util:document-name($doc)
  let $make-mirror-collection :=
   (: TODO: this should not have to be admin-ed. really, it should
   be setuid! :)
    system:as-user("admin", $magicpassword, 
      local:make-mirror-collection-path($ridx:ridx-collection, $collection)
    )
  let $mirror-collection :=
    app:concat-path(("/", $ridx:ridx-collection, $collection))
  let $owner := xmldb:get-owner($collection, $resource)
  let $group := xmldb:get-group($collection, $resource)
  let $mode := xmldb:get-permissions($collection, $resource)
  let $stored := 
    if (xmldb:store($mirror-collection, $resource, 
      element ridx:index {
        ridx:make-index-entries($doc//@target|$doc//@targets)
      }
    ))
    then 
      xmldb:set-resource-permissions(
        $mirror-collection, $resource,
        $owner, $group, $mode
      )
    else ()
  return () 
};

declare function ridx:make-index-entries(
  $reference-attributes as attribute()*
  ) as element()* {
  for $rattr in $reference-attributes
  let $element := $rattr/parent::element()
  let $ptr-node-id := util:node-id($element)
  let $type := ($element, $element/(ancestor::tei:linkGrp|ancestor::tei:joinGrp)[1])[1]/@type/string()
  for $follow at $n in tokenize($rattr/string(), "\s+")[not(starts-with(., "http://"))]
  let $null := util:log-system-out(("Following: ", $follow))
  let $returned := uri:follow-uri($follow, $element, uri:follow-steps($element))
  for $followed in $returned
  where $followed/@xml:id
  return
    element ridx:entry {
      util:log-system-out(("in link ", $element, " reference ", $followed/@xml:id/string(), " is $n = ", $n)),
      attribute ref { uri:absolutize-uri(concat("#", $followed/@xml:id/string()), $followed) },
      attribute ns { namespace-uri($element) },
      attribute local-name { local-name($element) },
      attribute n { $n },
      attribute type { $type },
      attribute node { $ptr-node-id }
    }
};

(:~ Look up if the current node specifically or, including any
 : of its ancestors (default true() unless $without-ancestors is set)
 : is referenced in a reference of type $ns:$local-name/@type, 
 : in the $n-th position
 : If any of the optional parameters are not found, do not limit
 : based on them.
 : The search is performed for nodes only within $context, which may be 
 : a collection or a document-node()
 :)
declare function ridx:lookup(
  $node as node(),
  $context as document-node()*,
  $ns as xs:string*,
  $local-name as xs:string*,
  $type as xs:string*,
  $n as xs:integer*,
  $without-ancestors as xs:boolean?
  ) as node()* {
  let $defaulted-context :=
    if (exists($context))
    then 
      for $c in $context
      return 
        doc(
          replace(document-uri($c), "^(/db)?/", 
            concat("/", $ridx:ridx-collection, "/")
          )
        )
    else collection(concat("/db/", $ridx:ridx-collection))
  let $nodes :=
    if ($without-ancestors) 
    then $node[@xml:id]
    else $node/ancestor-or-self::*[@xml:id]
  where exists($nodes)
  return
    let $uris := 
      for $nd in $nodes
      return 
        uri:absolutize-uri(
          concat("#", $nd/@xml:id/string()), $nd
        )
    for $entry in $defaulted-context//ridx:entry[
        @ref=$uris
        and
        (
          if (exists($ns))
          then @ns=$ns
          else true()
        ) and
        (
          if (exists($local-name))
          then @local-name=$local-name
          else true() 
        ) and
        (
          if (exists($n))
          then @n=$n
          else true()
        )
      ]
    let $original-doc := doc(
        replace(document-uri(root($entry)), concat("/", $ridx:ridx-collection), "")
      )
    return util:node-by-id($original-doc, $entry/@node)
};