import type { Metadata } from 'next';
import './globals.css';
export const metadata:Metadata={title:'绿电实验室 · 智能电表',description:'SDG 7 / 13 单电器用电监测、统计与节电分析',icons:{icon:'/favicon.svg'}};
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="zh-CN"><body>{children}</body></html>}
