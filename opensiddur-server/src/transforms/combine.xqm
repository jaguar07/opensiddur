xquery version "3.0";
(:~
 : Combine multiple documents into a single all-encompassing 
 : JLPTEI document
 :
 : Open Siddur Project
 : Copyright 2013-2014 Efraim Feinstein 
 : Licensed under the GNU Lesser General Public License, version 3 or later
 : 
 :)
module namespace combine="http://jewishliturgy.org/transform/combine";

import module namespace common="http://jewishliturgy.org/transform/common"
  at "../modules/common.xqm";
import module namespace data="http://jewishliturgy.org/modules/data"
  at "../modules/data.xqm";
import module namespace uri="http://jewishliturgy.org/transform/uri"
  at "../modules/follow-uri.xqm";
import module namespace format="http://jewishliturgy.org/modules/format"
  at "../modules/format.xqm";
import module namespace mirror="http://jewishliturgy.org/modules/mirror"
  at "../modules/mirror.xqm";
import module namespace ridx="http://jewishliturgy.org/modules/refindex"
  at "../modules/refindex.xqm";
import module namespace debug="http://jewishliturgy.org/transform/debug"
  at "../modules/debug.xqm";

declare namespace tei="http://www.tei-c.org/ns/1.0";
declare namespace j="http://jewishliturgy.org/ns/jlptei/1.0";
declare namespace jf="http://jewishliturgy.org/ns/jlptei/flat/1.0";

declare function combine:combine-document(
  $doc as document-node(),
  $params as map
  ) as document-node() {
  combine:combine($doc, $params)
};

declare function combine:combine(
  $nodes as node()*,
  $params as map
  ) as node()* {
  for $node in $nodes
  return
    typeswitch($node)
    case document-node() 
    return document { combine:combine($node/node(), $params)}
    case element(tei:TEI)
    return combine:tei-TEI($node, $params)
    case element(tei:teiHeader)
    return $node
    case element()
    return
        let $updated-params := combine:update-settings-from-standoff-markup($node, $params, false())
        return
            typeswitch($node)
            case element(tei:ptr)
            return combine:tei-ptr($node, $updated-params)
            (: TODO: add other model.resourceLike elements above :)
            case element(jf:unflattened)
            return combine:jf-unflattened($node, $updated-params)
            default (: other element :) 
            return combine:element($node, $updated-params) 
    default return $node
};

(:~ TEI is the root element :)
declare function combine:tei-TEI(
  $e as element(tei:TEI),
  $params as map
  ) as element(tei:TEI) {
  element { QName(namespace-uri($e), name($e)) }{
    $e/@*,
    combine:new-document-attributes((), $e),
    combine:combine(
      $e/node(), 
      combine:new-document-params($e, $params)
    )
  }
}; 

declare function combine:jf-unflattened(
  $e as element(jf:unflattened),
  $params as map
  ) as element(jf:combined) {
  element jf:combined {
    $e/@*,
    combine:combine($e/node(), $params)
  } 
};

declare function combine:element(
  $e as element(),
  $params as map
  ) as element() {
  element {QName(namespace-uri($e), name($e))}{
    $e/(@* except (@uri:*, @xml:id)),
    if ($e/@xml:id)
    then attribute jf:id { $e/@xml:id/string() }
    else (),
    combine:combine($e/node() ,$params)
  }
};

(:~ attributes that change on any context switch :)
declare function combine:new-context-attributes(
  $context as node()?,
  $new-context-nodes as node()*
  ) as node()* {
  let $new-language := (
    $new-context-nodes[not(@xml:lang)][1]/@uri:lang,
    let $new-lang-node := $new-context-nodes[not(@xml:lang)][1]
    where $new-lang-node
    return common:language($new-lang-node)
  )[1]
  return
    if (
      $new-language and 
      ($context and common:language($context) != $new-language))
    then 
      attribute xml:lang { $new-language }
    else ()
};

(:~ return the children (attributes and possibly other nodes)
 : that should be added when a document boundary is crossed 
 :)
declare function combine:new-document-attributes(
  $context as node()?,
  $new-doc-nodes as node()*
  ) as node()* {
  let $document-uri := 
    mirror:unmirror-path(
      $format:unflatten-cache,
      ( 
        document-uri(root($new-doc-nodes[1])), 
        ($new-doc-nodes[1]/@uri:document-uri)
      )[1]
    )
  return (
    (: document (as API source ), base URI?, language, source(?), 
     : license, contributors :)
    attribute jf:document { data:db-path-to-api($document-uri) },
    attribute jf:license { root($new-doc-nodes[1])//tei:licence/@target },
    combine:new-context-attributes($context, $new-doc-nodes)
  )
};

(:~ change parameters as required for entry into a new document
 : manages "combine:unmirrored-doc", "combine:setting-links" 
 :)
declare function combine:new-document-params(
  $new-doc-nodes as node()*,
  $params as map
  ) as map {
    let $unmirrored-path := 
        mirror:unmirror-path( (: 1/2db/3cache/4something/...:)
            $format:unflatten-cache, 
            document-uri(root($new-doc-nodes[1])))
    let $unmirrored-doc := doc($unmirrored-path)
    let $new-setting-links := $unmirrored-doc//tei:link[@type="set"]
    let $all-setting-links := ($params("combine:setting-links"), $new-setting-links)
    let $new-params := map:new((
        $params,
        map { 
            "combine:unmirrored-doc" := $unmirrored-doc,
            "combine:setting-links" := $all-setting-links
        }
    ))
    return
        combine:update-params($new-doc-nodes[1], $new-params)
}; 

(:~ update parameters are required for any new context :)
declare function combine:update-params(
  $node as node()?,
  $params as map
  ) as map {
  combine:update-settings-from-standoff-markup($node, $params, true())
};

(:~ update parameters with settings from standoff markup.
 : feature structures are represented by type->name->value
 : @param $params uses the combine:setting-links parameter, maintains the combine:settings parameter
 : @param $new-context true() if this is a new context 
 :)
declare function combine:update-settings-from-standoff-markup(
    $e as node(),
    $params as map,
    $new-context as xs:boolean
    ) as map {
    let $base-context :=
        if ($e/@jf:id)
        then $e
        else if ($new-context)
        then $e/ancestor::*[@jf:id]
        else ()
    return
        if ($base-context)
        then
            map:new((
                $params,
                map {
                    "combine:settings" := map:new((
                        $params("combine:settings"),
                        let $unmirrored := $params("combine:unmirrored-doc")//id($base-context/@jf:id)
                        for $standoff-link in 
                            ridx:query($params("combine:setting-links"), $unmirrored, 1, $new-context)
                        let $link-target := tokenize($standoff-link/(@target|@targets), '\s+')[2]
                        let $link-dest := uri:fast-follow($link-target, $unmirrored, uri:follow-steps($unmirrored))
                        where $link-dest instance of element(tei:fs)
                        return combine:tei-fs-to-map($link-dest)
                    ))
                } 
            ))
        else $params 
};

declare function combine:tei-fs-to-map(
    $e as element(tei:fs)
    ) as map {
    let $fsname := 
        if ($e/@type) 
        then $e/@type/string() 
        else ("anonymous:" || common:generate-id($e))
    return
        map:new(
            for $f in $e/tei:f
            return 
                map:entry(
                    $fsname || "->" ||
                    (
                        if ($f/@name)
                        then $f/@name/string()
                        else ("anonymous:" || common:generate-id($f))
                    ),
                    if ($f/@fVal)
                    then uri:fast-follow($f/@fVal, $f, -1)
                    else (
                        for $node in $f/node()
                        return 
                            typeswitch ($f/node())
                            case element(j:yes) return "YES"
                            case element(j:no) return "NO"
                            case element(j:maybe) return "MAYBE"
                            case element(j:on) return "ON"
                            case element(j:off) return "OFF"
                            case element(tei:binary) return string($node/@value=(1, "true"))
                            case element(tei:string) return $node/string()
                            case element() return $node/@value/string()
                            case text() return string($node)
                            default return ()
                    )[.][1]
                    (: TODO: default values :) 
                )
        )
};

(:~ get the effective document URI of the processing
 : context :)
declare function combine:document-uri(
  $context as node()?
  ) as xs:string? {
  (document-uri(root($context)),
  $context/ancestor-or-self::*
    [(@jf:document-uri|@uri:document-uri)][1]/
      (@jf:document-uri, @uri:document-uri)[1]/string()
  )[1]
};

(:~ handle a pointer :)
declare function combine:tei-ptr(
  $e as element(tei:ptr),
  $params as map
  ) as element()+ {
  if ($e/@type = "url")
  then combine:element($e, $params)
  else
    (: pointer to follow. 
     : This will naturally result in more than one jf:ptr per
     : tei:ptr if it has more than one @target, but that's OK.
     :)
    let $targets := tokenize($e/@target, '\s+')
    for $target in $targets
    let $destination := 
      uri:fast-follow(
        $target,
        $e,
        uri:follow-steps($e),
        (),
        true(),
        if (substring-before($target, "#") or not(contains($target, "#")))
        then $format:unflatten-cache
        else ( 
          (: Already in the cache, no need to try to 
          find a cache of a cached document :) 
        )
      )
    return
      element jf:ptr {
        $e/(@* except @target),  (: @target can be inferred :)
        if (
          combine:document-uri($e) = combine:document-uri($destination[1])
        )
        then 
          ((: internal pointer, partial context switch necessary:
            : lang, but not document-uri
           :)
           combine:new-context-attributes($e, $destination),
           combine:combine($destination,
              combine:update-params($destination, $params)
           )
          )
        else (
          combine:new-document-attributes($e, $destination),
          combine:combine($destination,
            combine:new-document-params($destination, $params))
        )
      }
};

