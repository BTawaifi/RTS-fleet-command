
          local target=makeTarget(21,'RED',7000,0); local defender=makeShip(22,'RED',7000,200)
          R.StrategicThreatSnapshot={{ship=defender,profile={value=500}}}
          local home=makeHome(); local bomber=makeGroup(1,target,'bomber',0,0,100)
          local fighter=makeGroup(2,target,'fighter',0,0,100)
          R:BuildAIOperations('BLUE',{bomber,fighter},home,0,10)
          local op=R.AIOperations.BLUE[21]
          R:BuildAIOperations('BLUE',{bomber,fighter},home,10,10); assert(op.phase=='APPROACH')
          bomber.units[1].Position=ba.createVector(7000,0,0); fighter.units[1].Position=ba.createVector(7000,0,0)
          R:BuildAIOperations('BLUE',{bomber,fighter},home,11,10); assert(op.phase=='ENGAGE')
          R.StrategicThreatSnapshot={}
          R:BuildAIOperations('BLUE',{bomber,fighter},home,12,0); assert(op.phase=='EXPLOIT')
          local ctx={}; local t,m=R:ApplyAIOperationOrder(bomber,target,'PRIMARY',ctx,home,12,{})
          print('CHK: t==target and m=='PRIMARY' and ctx.reason=='BREAKTHROUGH_EXPLOIT'  ==>  '..tostring(t==target and m=='PRIMARY' and ctx.reason=='BREAKTHROUGH_EXPLOIT'))
          bomber.value=1; fighter.value=1
          R.StrategicThreatSnapshot={{ship=defender,profile={value=500}}}
          R:BuildAIOperations('BLUE',{bomber,fighter},home,13,0); assert(op.phase=='WITHDRAW')
          local rt,rm=R:ApplyAIOperationOrder(bomber,target,'PRIMARY',{},home,13,{})
          print('CHK: rt==home and rm=='RETREAT'  ==>  '..tostring(rt==home and rm=='RETREAT'))
          R.StrategicThreatSnapshot={}; R:BuildAIOperations('BLUE',{bomber,fighter},home,18,0)
          print('CHK: op.phase=='ASSEMBLE'  ==>  '..tostring(op.phase=='ASSEMBLE'))
          R.AIHomeThreatHistory.BLUE=100
          R:BuildAIOperations('BLUE',{bomber,fighter},home,19,0)
          print('CHK: op.phase=='APPROACH' and op.serial==2  ==>  '..tostring(op.phase=='APPROACH' and op.serial==2))
          local found=false; for _,e in ipairs(R.events) do
            if e.name=='OPERATION' and e.data.reason=='COUNTERATTACK_WINDOW' then found=true end
          end
          print('CHK: found,'defeated raid did not trigger counterattack launch'  ==>  '..tostring(found,'defeated raid did not trigger counterattack launch'))
        