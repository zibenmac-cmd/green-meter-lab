import Dashboard from './dashboard';
import {requireChatGPTUser} from './chatgpt-auth';
export const dynamic='force-dynamic';
export default async function Home(){await requireChatGPTUser('/');return <Dashboard initialNow={Date.now()}/>;}
