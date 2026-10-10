import"./chunk-B6PJNJ2T.js";import"./chunk-LIBRLB4F.js";import"./chunk-MRBQJTHR.js";import"./chunk-XJGBVDZY.js";import"./chunk-FT3A7KB6.js";import"./chunk-IRMSHM5M.js";import"./chunk-LYEI6QVC.js";import{C as a,M as p,t as c,w as m}from"./chunk-AB55QZ56.js";import"./chunk-7YSPBAD3.js";import"./chunk-6J6Y2HEI.js";import"./chunk-2E3IWD2W.js";import"./chunk-DT4MQDPQ.js";import"./chunk-EEY3ZAKS.js";import"./chunk-U72QSA2E.js";import"./chunk-JMQUN7AV.js";var w=c`
  :host > wui-flex:first-child {
    height: 500px;
    overflow-y: auto;
    overflow-x: hidden;
    scrollbar-width: none;
  }

  :host > wui-flex:first-child::-webkit-scrollbar {
    display: none;
  }
`;var u=function(o,e,i,r){var l=arguments.length,t=l<3?e:r===null?r=Object.getOwnPropertyDescriptor(e,i):r,n;if(typeof Reflect=="object"&&typeof Reflect.decorate=="function")t=Reflect.decorate(o,e,i,r);else for(var f=o.length-1;f>=0;f--)(n=o[f])&&(t=(l<3?n(t):l>3?n(e,i,t):n(e,i))||t);return l>3&&t&&Object.defineProperty(e,i,t),t},s=class extends a{render(){return m`
      <wui-flex flexDirection="column" .padding=${["0","3","3","3"]} gap="3">
        <w3m-activity-list page="activity"></w3m-activity-list>
      </wui-flex>
    `}};s.styles=w;s=u([p("w3m-transactions-view")],s);export{s as W3mTransactionsView};
