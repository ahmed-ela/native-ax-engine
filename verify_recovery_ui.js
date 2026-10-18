'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const {loadReport} = require('./verify_tree_groups.js');
const template = fs.readFileSync(path.join(__dirname, 'tree_viewer.html'),'utf8');
const success={code:0,name:'success',attempts:1}, failure={code:-25200,name:'failure',attempts:1};
let fixtures=0;
function inspect(trace,attribute,value,hasValue,actionNames,issues=[],scalarVersion,topFields={}){
 const node={id:0,parent:null,children:[],native_children:[],role:'AXGroup',label:'Recovery fixture',value:'',identifier:'',description:'',actions:actionNames||[],leaf:'leaf',depth:0,attributes:{},hierarchy:{},references:[],issues:[],parameterized_names:[],attribute_names_status:{},action_names_status:{},parameterized_names_status:{},native_read_recoveries:{[attribute]:trace}};
 if(hasValue)node.attributes[attribute]=value;
 if(attribute==='action_names')node.action_names_status.native_read_recovery=trace;
 node.issues=issues;
 const payload={schema:'native-ax-tree-view/1',source:{},meta:{app:{name:'Fixture',bundle_id:'fixture.local',pid:1},node_count:1,leaf_count:1,unknown_leaf_count:0,hierarchy_failure_count:0,metadata_read_failure_count:issues.filter(i=>i.kind==='native_read').length,serialization_warning_count:0,metadata_breakdown:[],canonical_roots:[0],native_read_recovery_attempts:1,native_read_recovery_successes:trace.resolved?1:0},nodes:[node]};
 if(trace.resolution_kind!==undefined)Object.assign(payload.meta,{native_read_recovery_outcome_version:2,native_read_recovery_value_successes:trace.resolved && trace.resolution_kind==='value'?1:0,native_read_recovery_absence_successes:trace.resolved && trace.resolution_kind==='absence'?1:0});
 if(scalarVersion!==undefined)payload.meta.scalar_recovery_version=scalarVersion;
 Object.assign(payload.meta,topFields);
 const serialized=JSON.stringify(payload).replaceAll('<','\\u003c').replaceAll('>','\\u003e').replaceAll('&','\\u0026');
 const {document:doc}=loadReport(template.replace('__TREE_PAYLOAD__',serialized));
 const panel=doc.getElementById('detail-scroll');
 const section=panel.children.find(child=>child.querySelector('h2')?.textContent==='Native read recovery evidence');
 assert(section,'Recovery evidence section missing');
 const box=section.querySelector('.issue'),description=box.querySelector('span').textContent;
 const detail=box.querySelector('details');detail.open=true;detail.dispatchEvent({type:'toggle',bubbles:false});
 assert.deepEqual(JSON.parse(detail.querySelector('pre').textContent),trace,'Full recovery queries or initial status were altered');
 assert(doc.getElementById('coverage-body').textContent.includes('Each attempt may contain multiple native queries.'));
 if(trace.resolved && trace.resolution_kind==='absence')assert(box.querySelector('strong').textContent.includes('confirmed native absence'));
 else if(trace.resolved)assert(box.querySelector('strong').textContent.includes('resolved by native recovery'));
 else assert(box.querySelector('strong').textContent.includes('native recovery unresolved'));
 fixtures++;return {description,doc,compact:JSON.parse(box.querySelector('pre').textContent)};
}
for(const value of [false,0,'',[]]){
 const trace={method:'native_metadata_recovery',initial_status:failure,queries:[{method:'AXUIElementCopyMultipleAttributeValues',query_attributes:['AXRecovered'],options:0,query_status:success,has_array:true,returned_slot_count:1,slot_index:0,slot_attribute:'AXRecovered',item_kind:'value',cf_type_id:7,resolved:true,resolution_kind:'value'}],resolved:true,resolution_kind:'value',selected_method:'AXUIElementCopyMultipleAttributeValues'};
 const {description,doc}=inspect(trace,'AXRecovered',value,true);
 assert(description.includes('Recovered a native attribute value using AXUIElementCopyMultipleAttributeValues'));
 assert(!description.includes('before/after'),'Bulk scalar was mislabeled as a paged array');
 const attrs=doc.getElementById('detail-scroll').querySelectorAll('details').find(d=>d.querySelector('summary')?.textContent==='AXRecovered');
 attrs.open=true;attrs.dispatchEvent({type:'toggle',bubbles:false});assert.deepEqual(JSON.parse(attrs.querySelector('pre').textContent),value);
 assert(doc.getElementById('coverage-body').textContent.includes('1 recovered native values or enumerations + 0 confirmed native absences'));
}
for(const kind of ['null','ax_error','malformed']){
 const query={method:'AXUIElementCopyMultipleAttributeValues',query_attributes:['AXRecovered'],options:0,query_status:success,has_array:true,returned_slot_count:1,slot_index:0,slot_attribute:'AXRecovered',item_kind:kind,resolved:false};
 if(kind==='ax_error'){query.item_status=failure;query.item_error_decoded=true;}
 const trace={method:'native_metadata_recovery',initial_status:failure,queries:[query],resolved:false,resolution_kind:'unresolved',selected_method:null};
 const {description,doc}=inspect(trace,'AXRecovered',undefined,false);
 assert(description.includes('did not establish a successful value'));
 assert(description.includes('no empty value is inferred'));
 assert(!doc.getElementById('detail-scroll').querySelectorAll('details').some(d=>d.querySelector('summary')?.textContent==='AXRecovered'));
}
for(const actions of [[],['AXPress'],null]){
 const resolved=actions!==null,trace={method:'native_action_names_recovery',initial_status:failure,query_status:resolved?success:failure,has_array:resolved,returned_count:resolved?actions.length:null,resolved,resolution_kind:resolved?'value':'unresolved',names_valid:resolved,strings_count:resolved?actions.length:null};
 if(!resolved)trace.reason='Native action enumeration failed.';
 const {description}=inspect(trace,'action_names',undefined,false,actions);
 if(resolved){assert(description.includes('native action enumeration containing '+actions.length+' strings'));assert(!description.includes('array values'));}
 else {assert.equal(description,'Native action enumeration failed.');assert.equal(trace.strings_count,null);}
}
{
 const trace={method:'native_action_names_recovery',initial_status:failure,query_status:success,has_array:true,returned_count:2,names_valid:false,strings_count:1,resolved:false,resolution_kind:'unresolved'};
 const {description,doc}=inspect(trace,'action_names',undefined,false);
 assert(description.includes('not a valid action string array'));
 assert(description.includes('No action names are inferred'));
 const summary=doc.getElementById('detail-scroll').children.find(child=>child.querySelector('h2')?.textContent==='Native read recovery evidence').querySelector('.issue').querySelector('pre');
 const compact=JSON.parse(summary.textContent);assert.equal(compact.names_valid,false);assert.equal(compact.strings_count,1);assert.equal(compact.has_array,true);
}
for(const count of [0,2]){
 const trace={method:'AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues',initial_status:failure,count_before_status:success,count_before:count,pages:count?[{index:0,requested:2,status:success}]:[],count_after_status:success,count_after:count,resolved:true,returned_count:count};
 const {description,doc}=inspect(trace,'AXRecovered',Array(count).fill(1),true);
 assert(description.includes('Recovered '+count+' native array values with matching recorded before/after counts'));
 assert(doc.getElementById('coverage-body').textContent.includes('This legacy export has no separate value/absence outcome counters.'));
}
{
 const noValue={code:-25212,name:'noValue',attempts:1},query={method:'AXUIElementCopyMultipleAttributeValues',query_attributes:['AXRecovered'],options:0,query_status:success,has_array:true,returned_slot_count:1,slot_index:0,slot_attribute:'AXRecovered',item_kind:'ax_error',item_error_decoded:true,item_status:noValue,cf_type_id:156,resolved:true,resolution_kind:'absence'};
 const trace={method:'native_metadata_recovery',initial_status:failure,queries:[query],resolved:true,resolution_kind:'absence',selected_method:'AXUIElementCopyMultipleAttributeValues'};
 const {description,doc,compact}=inspect(trace,'AXRecovered',undefined,false);
 assert(description.includes('native noValue response confirmed absence'));
 assert(description.includes('No content or empty array was recovered'));
 assert(!description.includes('Recovered a native attribute value'));
 assert.equal(compact.resolution_kind,'absence');assert.deepEqual(compact.initial_status,failure);assert.deepEqual(compact.decoded_native_item_status,noValue);assert.deepEqual(compact.selected_query_status,success);
 assert(!doc.getElementById('detail-scroll').querySelectorAll('details').some(d=>d.querySelector('summary')?.textContent==='AXRecovered'),'Confirmed noValue fabricated an attribute value');
 assert(doc.getElementById('coverage-body').textContent.includes('0 recovered native values or enumerations + 1 confirmed native absences (1 resolved outcomes)'));
}
// Actual template execution verifies the fresh scalar route without consulting
// a live native app. No failed or missing native response becomes a fake value.
const scalarScenarios=['value','absence','query_failure','wrong_type','target_mismatch','process_changed','unsupported'];
for(const [scalarVersion,scenario] of [1,2].flatMap(version=>scalarScenarios.map(scenario=>[version,scenario]))){
 const noValue={code:-25212,name:'noValue',attempts:1},unsupported={code:-25205,name:'attributeUnsupported',attempts:1};
 const attribute=scalarVersion===2?'AXTopLevelUIElement':'AXGrowArea',eligible=scalarVersion===2 || scenario!=='unsupported';
 const initial=scalarVersion===2 || scenario==='unsupported'?unsupported:failure,resolved=['value','absence'].includes(scenario),outcome=resolved?scenario:'unresolved';
 const bulk={method:'AXUIElementCopyMultipleAttributeValues',query_attributes:[attribute],options:0,query_status:success,has_array:true,returned_slot_count:1,slot_index:0,slot_attribute:attribute,item_kind:'ax_error',item_status:initial,item_error_decoded:true,resolved:false,resolution_kind:'unresolved'};
 const trace={method:'native_metadata_recovery',initial_status:initial,queries:[bulk],documented_scalar:{attribute,expected_value_kind:'AXUIElement',array_query_skipped:true,scalar_retry_eligible:eligible},resolved,resolution_kind:outcome,selected_method:resolved?'native_scalar_recovery':null};
 let scalar;
 if(eligible){
  const refresh={attempted:true,selector_path:[{attribute:'AXWindows',index:0}],root_pid:123,expected_pid:123,process_identity_matches:true,root_same_element:true,root_timeout_status:success,steps:[{attribute:'AXWindows',status:success,same_element:true,expected_pid:123}],same_element:scenario!=='target_mismatch',pid_status:success,pid:123,resolved:scenario!=='target_mismatch'};
  if(scenario==='target_mismatch')refresh.reason='Native element identity differs from the recorded target.';
  const validation={expected_value_kind:'AXUIElement',expected_cf_type_id:101,has_value:['value','wrong_type','process_changed'].includes(scenario),cf_type_id:scenario==='wrong_type'?7:101,ax_value_type:null,ax_value_decoded:null,valid:['value','process_changed'].includes(scenario)};
  scalar={method:'native_scalar_recovery',attribute,expected_value_kind:'AXUIElement',initial_status:initial,query_method:'AXUIElementCopyAttributeValue',refresh,query_status:scenario==='target_mismatch'?null:scenario==='absence'?noValue:scenario==='unsupported'?unsupported:scenario==='query_failure'?failure:success,query_process_identity_matches:scenario==='target_mismatch'?null:scenario!=='process_changed',value_validation:scenario==='target_mismatch'?null:validation,resolved,resolution_kind:outcome};
  trace.queries.push(scalar);
 }
 const issues=resolved?[]:[{node:0,kind:'native_read',attribute,stage:'attribute_read',status:{...initial,native_read_recovery:trace},native_attribute_advertised:true}];
 const {description,doc,compact}=inspect(trace,attribute,{type:'AXUIElement',id:1},scenario==='value',undefined,issues,scalarVersion);
 assert.deepEqual(compact.initial_status,initial);assert.deepEqual(compact.documented_scalar,trace.documented_scalar);
 if(scalar){
  assert.deepEqual(compact.scalar_query_status,scalar.query_status);
  assert.equal(compact.scalar_query_process_identity_matches,scalar.query_process_identity_matches);
  assert.deepEqual(compact.scalar_value_validation,scalar.value_validation);
  assert.equal(compact.scalar_target_refresh.root_same_element,true);
  assert.equal(compact.scalar_target_refresh.same_element,scalar.refresh.same_element);
  assert.equal(compact.scalar_target_refresh.pid,123);
  assert.equal(compact.scalar_target_refresh.process_identity_matches,true);
 }
 if(scenario==='value')assert(description.includes('Recovered a typed native AXUIElement value with one bounded fresh exact-target AXUIElementCopyAttributeValue query'));
 else if(scenario==='absence'){assert(description.includes('confirmed absence'));assert.equal(compact.selected_query_status.code,-25212);assert(!description.includes('Recovered a typed'));}
 else if(scenario==='target_mismatch')assert(description.includes('query was withheld because its exact native target was not verified'));
 else if(scenario==='unsupported' && !eligible){assert(description.includes('Fresh scalar retry was not eligible'));assert(!('scalar_query_status' in compact));}
 else assert(description.includes('did not resolve a valid typed value or confirmed absence'));
 if(scalarVersion===2 && scenario==='value')assert(description.includes('The original attributeUnsupported response remains recorded'));
 if(!resolved)assert(description.includes('known scalar AXUIElement value kind'));
 const valueDetails=doc.getElementById('detail-scroll').querySelectorAll('details').filter(d=>d.querySelector('summary')?.textContent===attribute);
 assert.equal(valueDetails.length,scenario==='value'?1:0,'Unresolved scalar or native absence fabricated an attribute');
 if(issues.length){
  const issue=doc.getElementById('issue-0-0');assert(issue,'Original scalar read failure disappeared');
  assert.deepEqual(JSON.parse(issue.querySelector('pre').textContent),issues[0]);
 }
}
// Version 3 may query the retained original menu owner. The fresh refresh must
// stay failed, even when its separately validated original reference succeeds.
for(const scenario of ['value','absence','unsupported','invalid_element','wrong_type','process_changed','refused_retention']){
 const attribute='AXTopLevelUIElement',unsupported={code:-25205,name:'attributeUnsupported',attempts:1},noValue={code:-25212,name:'noValue',attempts:1},invalidElement={code:-25202,name:'invalidUIElement',attempts:1};
 const resolved=['value','absence'].includes(scenario),queried=scenario!=='refused_retention',outcome=resolved?scenario:'unresolved';
 const refresh={attempted:true,selector_path:[{attribute:'AXMenuBar',value_path:[]}],root_pid:123,expected_pid:123,process_identity_matches:true,root_same_element:true,root_timeout_status:success,steps:[{step:0,attribute:'AXMenuBar',value_path:[],path_steps:[],query_status:success,has_value:true,selected_is_element:true,selected_cf_type_id:101,pid_status:success,pid:123,expected_pid:123,process_identity_matches:true,same_element:false,resolved:false}],same_element:null,pid_status:null,pid:null,resolved:false,reason:'Fresh native prefix differs from the captured element.'};
 const retained={attempted:true,source:'capture_registry',node_id:0,root_id:0,root_pid:123,expected_pid:123,owner_role:'AXMenuItem',owner_role_status:success,expected_cf_type_id:101,owner_cf_type_id:101,registry_binding_matches:queried,root_pid_status:queried?success:null,root_native_pid:queried?123:null,owner_pid_status:queried?success:null,owner_native_pid:queried?123:null,root_process_identity_matches:queried?true:null,owner_process_identity_matches:queried?true:null,resolved:queried};
 if(!queried)retained.reason='Retained query target is not the exact original capture-registry owner.';
 const post=queried?{...retained,owner_process_identity_matches:scenario!=='process_changed',resolved:scenario!=='process_changed'}:null;
 if(post && !post.resolved)post.reason='Captured root or retained owner process/launch identity changed.';
 const validation=queried?{expected_value_kind:'AXUIElement',expected_cf_type_id:101,has_value:['value','wrong_type','process_changed'].includes(scenario),cf_type_id:scenario==='wrong_type'?7:['value','process_changed'].includes(scenario)?101:null,ax_value_type:null,ax_value_decoded:null,valid:['value','process_changed'].includes(scenario)}:null;
 const scalar={method:'native_scalar_recovery',attribute,expected_value_kind:'AXUIElement',initial_status:unsupported,query_method:'AXUIElementCopyAttributeValue',refresh,query_target:queried?'retained_original_reference':null,retained_reference:retained,query_retained_reference_validation:post,query_status:!queried?null:scenario==='absence'?noValue:scenario==='unsupported'?unsupported:scenario==='invalid_element'?invalidElement:success,query_process_identity_matches:queried?scenario!=='process_changed':null,value_validation:validation,resolved,resolution_kind:outcome};
 const bulk={method:'AXUIElementCopyMultipleAttributeValues',query_attributes:[attribute],options:0,query_status:success,has_array:true,returned_slot_count:1,slot_index:0,slot_attribute:attribute,item_kind:'ax_error',item_status:unsupported,item_error_decoded:true,resolved:false,resolution_kind:'unresolved'};
 const trace={method:'native_metadata_recovery',initial_status:unsupported,queries:[bulk,scalar],documented_scalar:{attribute,expected_value_kind:'AXUIElement',array_query_skipped:true,scalar_retry_eligible:true},resolved,resolution_kind:outcome,selected_method:resolved?'native_scalar_recovery':null};
 const issues=resolved?[]:[{node:0,kind:'native_read',attribute,stage:'attribute_read',status:{...unsupported,native_read_recovery:trace},native_attribute_advertised:true}];
 const top={native_scalar_retained_reference_attempts:Number(queried),native_scalar_retained_reference_withheld:Number(!queried),native_scalar_retained_reference_value_successes:Number(scenario==='value'),native_scalar_retained_reference_absence_successes:Number(scenario==='absence')};
 const {description,doc,compact}=inspect(trace,attribute,{type:'AXUIElement',id:1},scenario==='value',undefined,issues,3,top);
 assert.equal(compact.scalar_query_target,scalar.query_target);
 assert.deepEqual(compact.scalar_retained_reference,retained);
 assert.deepEqual(compact.scalar_query_retained_reference_validation,post);
 assert.equal(compact.scalar_target_refresh.resolved,false,'Successful retained query concealed the failed fresh refresh');
 assert.equal(compact.scalar_query_process_identity_matches,scalar.query_process_identity_matches);
 assert.deepEqual(compact.scalar_value_validation,validation);
 assert(description.includes(queried?'retained original reference':'withheld'));
 if(queried){assert(description.includes('failed fresh refresh remains recorded'));assert(description.includes('does not establish current tree membership'));assert(!description.includes('fresh exact-target'));}
 if(scenario==='value')assert(description.includes('Recovered a typed native AXUIElement value'));
 else if(scenario==='absence')assert(description.includes('No content or empty array was recovered'));
 else if(queried)assert(description.includes('did not resolve a valid typed value or confirmed absence'));
 else assert(description.includes('retained original reference did not pass validation'));
 const attributes=doc.getElementById('detail-scroll').querySelectorAll('details').filter(d=>d.querySelector('summary')?.textContent===attribute);
 assert.equal(attributes.length,scenario==='value'?1:0,'Retained failure or native absence fabricated a value');
 const coverage=doc.getElementById('coverage-body').textContent;
 assert(coverage.includes('Retained original reference queries: '+Number(queried)+' issued; '+Number(!queried)+' withheld after failed validation'));
 assert(coverage.includes(Number(scenario==='value')+' typed native values; '+Number(scenario==='absence')+' confirmed native absences'));
 assert(coverage.includes('These outcomes are included in native recovery totals'));
 if(issues.length){assert.deepEqual(JSON.parse(doc.getElementById('issue-0-0').querySelector('pre').textContent),issues[0]);doc.querySelector('[data-category="native_read"]').click();assert.equal(doc.getElementById('category-list').children.length,1);}
}
for(const advertised of [true,null]){
 const unsupported={code:-25205,name:'attributeUnsupported',attempts:1};
 const trace={method:'native_metadata_recovery',initial_status:unsupported,queries:[],documented_scalar:{attribute:'AXTopLevelUIElement',expected_value_kind:'AXUIElement',array_query_skipped:true,scalar_retry_eligible:false},resolved:false,resolution_kind:'unresolved',selected_method:null};
 const issue={kind:'native_read',node:0,attribute:'AXTopLevelUIElement',stage:advertised?'attribute_read':'attribute_names',status:unsupported,native_attribute_advertised:advertised};
 const {doc}=inspect(trace,'AXTopLevelUIElement',undefined,false,undefined,[issue]);
 assert(doc.getElementById('native-read-summary').textContent.includes('1 native unsupported reads; 0 other read failures'));
 const classification=doc.getElementById('issue-0-0').querySelector('span').textContent;
 assert(classification.includes(advertised?'Advertised but unsupported':'Native unsupported read'));
 assert.equal(classification.includes('Advertised but unsupported'),advertised===true);
 doc.querySelector('[data-category="native_read"]').click();
 const rows=doc.getElementById('category-list').children;
 assert.equal(rows.length,1,'Unsupported native record disappeared from its existing summary group');
 assert(rows[0].textContent.includes(advertised?'Advertised but unsupported':'Native unsupported read'));
}
console.log(JSON.stringify({native_recovery_ui_fixtures_passed:fixtures,actual_template_javascript:true,queries_and_original_status_preserved:true,no_live_app_browser_or_http:true}));
